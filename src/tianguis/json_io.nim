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
import kdl
import ./model

# Re-export kdl so consumers calling parseJson get access to Result's
# .isOk / .get accessors without needing a separate `import kdl`.
export kdl

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

proc versionToJson(v: Version): JsonNode =
  %*{
    "version":      v.version,
    "content_hash": v.contentHash,
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
  ## Emit canonical JSON for an Index.
  let pkgs = newJArray()
  for pkg in idx.packages:
    pkgs.add(packageToJson(pkg))
  let node = %*{
    "schema_version": idx.schemaVersion,
    "packages":       pkgs,
  }
  $node

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

proc versionFromJson(node: JsonNode): Version =
  Version(
    version:     node{"version"}.getStr(""),
    contentHash: node{"content_hash"}.getStr(""),
    attestation: node{"attestation"}.getStr(""),
    signedBy:    node{"signed_by"}.getStr(""),
    publishedAt: node{"published_at"}.getStr(""),
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

proc parseJson*(s: string): Result[Index, string] =
  ## Parse canonical JSON into an Index. Returns an Err with a
  ## human-readable description on any failure.
  let node = try:
    stdjson.parseJson(s)
  except JsonParsingError as e:
    return err[Index, string]("malformed JSON: " & e.msg)
  if node.kind != JObject:
    return err[Index, string](
      "root must be a JSON object, got " & $node.kind
    )
  let sv = node{"schema_version"}.getInt(0)
  var packages: seq[Package] = @[]
  let pkgsNode = node{"packages"}
  if pkgsNode != nil and pkgsNode.kind == JArray:
    for item in pkgsNode:
      packages.add(packageFromJson(item))
  ok[Index, string](Index(schemaVersion: sv, packages: packages))
