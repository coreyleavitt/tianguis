## JSON projection of the tianguis Index data model.
##
## JSON is the cross-ecosystem interop format — every dashboard, mirror,
## search tool, or non-milpa client reads index.json. KDL is canonical;
## JSON is auto-derived from the same data model.
##
## Bijection with the model is the load-bearing property:
##   parseJson(formatJson(idx)).get == idx
## for every valid Index value.

import std/json as stdjson
import std/tables
import nkdl   # Result / ok / err (re-exported from nkdl/spans)
import ./model
import ./errors

# Re-export nkdl + errors so consumers calling parseJson get access to
# Result's .isOk / .get accessors and IDX-* codes without separate imports.
export nkdl, errors

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

proc provenanceToJson(p: Provenance): JsonNode =
  case p.kind
  of pkGit:
    %*{
      "kind":       "git",
      "url":        p.url,
      "ref":        p.gitRef,
      "commit_sha": p.commitSha,
    }
  of pkOci:
    %*{
      "kind":       "oci",
      "registry":   p.registry,
      "repository": p.repository,
      "digest":     p.digest,
    }

proc versionToJson(v: Version): JsonNode =
  let provs = newJArray()
  for p in v.provenances:
    provs.add(provenanceToJson(p))
  let reqs = newJObject()
  for name, constraint in v.requires.pairs:
    reqs[name] = %constraint
  %*{
    "version":      v.version,
    "content_hash": v.contentHash,
    "requires":     reqs,
    "provenances":  provs,
    "attestation":  v.attestation,
    "signed_by":    v.signedBy,
    "published_at": v.publishedAt,
  }

proc packageToJson(pkg: Package): JsonNode =
  let versions = newJArray()
  for v in pkg.versions:
    versions.add(versionToJson(v))
  %*{
    "name":      pkg.name,
    "namespace": pkg.namespace,
    "upstream":  pkg.upstream,
    "versions":  versions,
  }

proc formatJson*(idx: Index): string =
  ## Emit canonical JSON for an Index. Canonicalizes ordering first
  ## so packages are alphabetical and versions are descending semver.
  let canon = canonicalize(idx)
  let pkgs = newJArray()
  for pkg in canon.packages:
    pkgs.add(packageToJson(pkg))
  let node = %*{
    "schema_version": canon.schemaVersion,
    "packages":       pkgs,
  }
  $node

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

proc provenanceFromJson(node: JsonNode): Provenance =
  let kindStr = node{"kind"}.getStr("git")
  case kindStr
  of "oci":
    Provenance(
      kind:       pkOci,
      registry:   node{"registry"}.getStr(""),
      repository: node{"repository"}.getStr(""),
      digest:     node{"digest"}.getStr(""),
    )
  else:
    Provenance(
      kind:      pkGit,
      url:       node{"url"}.getStr(""),
      gitRef:    node{"ref"}.getStr(""),
      commitSha: node{"commit_sha"}.getStr(""),
    )

proc versionFromJson(node: JsonNode): Version =
  var provs: seq[Provenance] = @[]
  let pNode = node{"provenances"}
  if pNode != nil and pNode.kind == JArray:
    for item in pNode:
      provs.add(provenanceFromJson(item))
  var reqs = initOrderedTable[string, string]()
  let rNode = node{"requires"}
  if rNode != nil and rNode.kind == JObject:
    for k, v in rNode:
      reqs[k] = v.getStr("")
  Version(
    version:     node{"version"}.getStr(""),
    contentHash: node{"content_hash"}.getStr(""),
    attestation: node{"attestation"}.getStr(""),
    signedBy:    node{"signed_by"}.getStr(""),
    publishedAt: node{"published_at"}.getStr(""),
    provenances: provs,
    requires:    reqs,
  )

proc packageFromJson(node: JsonNode): Package =
  var versions: seq[Version] = @[]
  let vNode = node{"versions"}
  if vNode != nil and vNode.kind == JArray:
    for item in vNode:
      versions.add(versionFromJson(item))
  Package(
    name:      node{"name"}.getStr(""),
    namespace: node{"namespace"}.getStr(""),
    upstream:  node{"upstream"}.getStr(""),
    versions:  versions,
  )

const TopLevelKeys = ["schema_version", "packages"]

proc parseJson*(s: string): Result[Index, IdxError] =
  ## Parse canonical JSON into an Index. Strict-schema: unknown keys
  ## at the root produce IDX-NODE-UNKNOWN. Nested strict-schema for
  ## package/version/provenance lands when the JSON path catches up to
  ## the KDL path.
  let node = try:
    stdjson.parseJson(s)
  except JsonParsingError as e:
    return err[Index, IdxError](initIndexError(
      iecJsonParse, "malformed JSON: " & e.msg
    ))
  if node.kind != JObject:
    return err[Index, IdxError](initIndexError(
      iecBadType, "root must be a JSON object, got " & $node.kind
    ))
  for k, _ in node:
    if k notin TopLevelKeys:
      return err[Index, IdxError](initIndexError(
        iecUnknownNode, "unknown top-level key '" & k & "'"
      ))
  let sv = node{"schema_version"}.getInt(0)
  var packages: seq[Package] = @[]
  let pkgsNode = node{"packages"}
  if pkgsNode != nil and pkgsNode.kind == JArray:
    for item in pkgsNode:
      packages.add(packageFromJson(item))
  ok[Index, IdxError](Index(schemaVersion: sv, packages: packages))
