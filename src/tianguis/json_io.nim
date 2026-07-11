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
import std/options
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
  let obj = %*{
    "version":      v.version,
    "content_hash": v.contentHash,
    "requires":     reqs,
    "provenances":  provs,
    "attestation":  v.attestation,
    "signed_by":    v.signedBy,
    "published_at": v.publishedAt,
  }
  # Author-signed durable Rekor pointer — emitted only when present (the site
  # reads index.json, so the field must project here too). Absent on
  # milpa-vendored versions.
  if v.rekor.isSome:
    let rk = v.rekor.get
    obj["rekor"] = %*{
      "uuid":            rk.uuid,
      "log_index":       rk.logIndex,
      "integrated_time": rk.integratedTime,
    }
  # Delivery-integrity pin: sha256 of the attestation bundle BYTES. Emitted
  # only when present, mirroring `rekor` (absent = not yet minted).
  if v.bundlePin.isSome:
    obj["bundle_pin"] = %v.bundlePin.get
  obj

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
  var rekor = none(RekorRef)
  let rkNode = node{"rekor"}
  if rkNode != nil and rkNode.kind == JObject:
    rekor = some(RekorRef(
      uuid:           rkNode{"uuid"}.getStr(""),
      logIndex:       rkNode{"log_index"}.getStr(""),
      integratedTime: rkNode{"integrated_time"}.getStr(""),
    ))
  var bundlePin = none(string)
  let bpNode = node{"bundle_pin"}
  if bpNode != nil and bpNode.kind == JString:
    bundlePin = some(bpNode.getStr(""))
  Version(
    version:     node{"version"}.getStr(""),
    contentHash: node{"content_hash"}.getStr(""),
    attestation: node{"attestation"}.getStr(""),
    signedBy:    node{"signed_by"}.getStr(""),
    publishedAt: node{"published_at"}.getStr(""),
    provenances: provs,
    rekor:       rekor,
    bundlePin:   bundlePin,
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

# ---------------------------------------------------------------------------
# Strict-schema validation (#16) — parity with parseKdl's per-context
# IDX-NODE-UNKNOWN rejection. JSON has no native line/col, so the location is
# a path-style context string (e.g. "packages[0].versions[0]"). The allowed
# key sets mirror the KDL child whitelists in kdl_io (package/version/
# provenance/rekor); `requires` keys are dynamic dep names (data, not schema)
# and are intentionally not validated, exactly as on the KDL side.
# ---------------------------------------------------------------------------

const
  TopLevelKeys       = ["schema_version", "packages"]
  JsonPackageKeys    = ["name", "namespace", "upstream", "versions"]
  JsonVersionKeys    = ["version", "content_hash", "requires", "provenances",
                        "attestation", "signed_by", "published_at", "rekor",
                        "bundle_pin"]
  JsonProvenanceKeys = ["kind", "url", "ref", "commit_sha",
                        "registry", "repository", "digest"]
  JsonRekorKeys      = ["uuid", "log_index", "integrated_time"]

proc unknownKeyIn(node: JsonNode, allowed: openArray[string],
                  ctx: string): Option[IdxError] =
  ## Strict membership for a JSON object's keys; `none` when all keys are in
  ## `allowed`. Non-objects are skipped (their shape is checked elsewhere).
  if node.kind != JObject: return none(IdxError)
  for k, _ in node:
    if k notin allowed:
      return some(initIndexError(
        iecUnknownNode, "unknown key '" & k & "' in " & ctx))
  none(IdxError)

proc validateVersionJson(node: JsonNode, ctx: string): Option[IdxError] =
  let e = unknownKeyIn(node, JsonVersionKeys, ctx)
  if e.isSome: return e
  let provs = node{"provenances"}
  if provs != nil and provs.kind == JArray:
    for i, p in provs.elems:
      let pe = unknownKeyIn(p, JsonProvenanceKeys,
                            ctx & ".provenances[" & $i & "]")
      if pe.isSome: return pe
  let rekor = node{"rekor"}
  if rekor != nil and rekor.kind == JObject:
    let re = unknownKeyIn(rekor, JsonRekorKeys, ctx & ".rekor")
    if re.isSome: return re
  none(IdxError)

proc validatePackageJson(node: JsonNode, ctx: string): Option[IdxError] =
  let e = unknownKeyIn(node, JsonPackageKeys, ctx)
  if e.isSome: return e
  let versions = node{"versions"}
  if versions != nil and versions.kind == JArray:
    for i, v in versions.elems:
      let ve = validateVersionJson(v, ctx & ".versions[" & $i & "]")
      if ve.isSome: return ve
  none(IdxError)

proc validateIndexJson(node: JsonNode): Option[IdxError] =
  let e = unknownKeyIn(node, TopLevelKeys, "(root)")
  if e.isSome: return e
  let pkgs = node{"packages"}
  if pkgs != nil and pkgs.kind == JArray:
    for i, p in pkgs.elems:
      let pe = validatePackageJson(p, "packages[" & $i & "]")
      if pe.isSome: return pe
  none(IdxError)

proc parseJson*(s: string): Result[Index, IdxError] =
  ## Parse canonical JSON into an Index. Strict-schema at every level:
  ## unknown keys in the root, package, version, provenance, or rekor objects
  ## produce IDX-NODE-UNKNOWN with a path-style location (#16 — parity with
  ## parseKdl).
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
  let verr = validateIndexJson(node)
  if verr.isSome:
    return err[Index, IdxError](verr.get)
  let sv = node{"schema_version"}.getInt(0)
  var packages: seq[Package] = @[]
  let pkgsNode = node{"packages"}
  if pkgsNode != nil and pkgsNode.kind == JArray:
    for item in pkgsNode:
      packages.add(packageFromJson(item))
  ok[Index, IdxError](Index(schemaVersion: sv, packages: packages))
