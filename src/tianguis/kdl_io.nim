## KDL projection of the tianguis Index data model.
##
## Hand-rolled parse/format against the kdl library's AST primitives.
## The library's deriveDecode/deriveEncode macros are an option for
## later; for now the index grammar is small enough that explicit
## traversal is clearer and easier to evolve as we grow the schema.

import kdl
import ./model

# Re-export kdl so consumers calling parseKdl get access to Result's
# .isOk / .get accessors without needing a separate `import kdl`.
export kdl

proc formatKdl*(idx: Index): string =
  ## Emit canonical KDL for an Index.
  result.add("schema_version " & $idx.schemaVersion & "\n")

proc parseKdl*(s: string): Result[Index, ParseError] =
  ## Parse canonical KDL into an Index. Unknown top-level nodes are
  ## currently tolerated; strict-schema enforcement lands in a later
  ## cycle alongside the IDX-* error catalog.
  let doc = parse(s)
  if doc.isErr:
    return err[Index, ParseError](doc.getErr)

  var idx = Index(schemaVersion: 0, packages: @[])
  let parsed = doc.get
  for node in parsed.nodes:
    let name = parsed.interner.lookup(node.name)
    if name == "schema_version":
      idx.schemaVersion = node.entries[0].argValue.intVal.int
  ok[Index, ParseError](idx)
