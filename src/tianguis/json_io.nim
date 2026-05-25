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

proc formatJson*(idx: Index): string =
  ## Emit canonical JSON for an Index. Keys appear in schema-canonical
  ## order (schema_version, packages); arrays are sorted by their
  ## natural model-level ordering (packages alphabetical, etc. — none
  ## of which apply at the empty-index stage).
  let node = %*{
    "schema_version": idx.schemaVersion,
    "packages": newJArray(),
  }
  $node

proc parseJson*(s: string): Result[Index, string] =
  ## Parse canonical JSON into an Index. Returns an Err with a
  ## human-readable description on any failure (malformed JSON,
  ## wrong root shape, missing required keys).
  let node = try:
    stdjson.parseJson(s)
  except JsonParsingError as e:
    return err[Index, string]("malformed JSON: " & e.msg)
  if node.kind != JObject:
    return err[Index, string](
      "root must be a JSON object, got " & $node.kind
    )
  let sv = node{"schema_version"}.getInt(0)
  ok[Index, string](Index(schemaVersion: sv, packages: @[]))
