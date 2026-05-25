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

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

proc formatVersion(v: Version, indent: string): string =
  result.add(indent & "version \"" & v.version & "\" {\n")
  result.add(indent & "    content_hash \"" & v.contentHash & "\"\n")
  result.add(indent & "    attestation \"" & v.attestation & "\"\n")
  result.add(indent & "    signed_by \"" & v.signedBy & "\"\n")
  result.add(indent & "    published_at \"" & v.publishedAt & "\"\n")
  result.add(indent & "}\n")

proc formatPackage(pkg: Package): string =
  result.add("package \"" & pkg.name & "\" {\n")
  result.add("    namespace \"" & pkg.namespace & "\"\n")
  result.add("    upstream (url)\"" & pkg.upstream & "\"\n")
  for v in pkg.versions:
    result.add(formatVersion(v, "    "))
  result.add("}\n")

proc formatKdl*(idx: Index): string =
  ## Emit canonical KDL for an Index.
  result.add("schema_version " & $idx.schemaVersion & "\n")
  for pkg in idx.packages:
    result.add(formatPackage(pkg))

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

proc parseVersion(doc: KdlDoc, node: KdlNode): Version =
  result = Version(version: node.entries[0].argValue.strVal)
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    case childName
    of "content_hash": result.contentHash = child.entries[0].argValue.strVal
    of "attestation":  result.attestation = child.entries[0].argValue.strVal
    of "signed_by":    result.signedBy    = child.entries[0].argValue.strVal
    of "published_at": result.publishedAt = child.entries[0].argValue.strVal
    else: discard

proc parsePackage(doc: KdlDoc, node: KdlNode): Package =
  result = Package(name: node.entries[0].argValue.strVal)
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    case childName
    of "namespace": result.namespace = child.entries[0].argValue.strVal
    of "upstream":  result.upstream  = child.entries[0].argValue.strVal
    of "version":   result.versions.add(parseVersion(doc, child))
    else: discard

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
    case name
    of "schema_version":
      idx.schemaVersion = node.entries[0].argValue.intVal.int
    of "package":
      idx.packages.add(parsePackage(parsed, node))
    else: discard
  ok[Index, ParseError](idx)
