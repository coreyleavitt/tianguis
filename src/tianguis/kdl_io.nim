## KDL projection of the tianguis Index data model.
##
## Hand-rolled parse/format against the kdl library's AST primitives.
## The library's deriveDecode/deriveEncode macros are an option for
## later; for now the index grammar is small enough that explicit
## traversal is clearer and easier to evolve as we grow the schema.

import std/tables
import kdl
import ./model

# Re-export kdl so consumers calling parseKdl get access to Result's
# .isOk / .get accessors without needing a separate `import kdl`.
export kdl

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

proc formatProvenance(p: Provenance, indent: string): string =
  result.add(indent & "provenance {\n")
  result.add(indent & "    kind \"" & $p.kind & "\"\n")
  case p.kind
  of pkGit:
    result.add(indent & "    url (url)\"" & p.url & "\"\n")
    result.add(indent & "    ref \"" & p.gitRef & "\"\n")
    result.add(indent & "    commit_sha \"" & p.commitSha & "\"\n")
  of pkOci:
    result.add(indent & "    registry \"" & p.registry & "\"\n")
    result.add(indent & "    repository \"" & p.repository & "\"\n")
    result.add(indent & "    digest \"" & p.digest & "\"\n")
  result.add(indent & "}\n")

proc formatRequires(r: OrderedTable[string, string], indent: string): string =
  if r.len == 0: return
  result.add(indent & "requires {\n")
  for name, constraint in r.pairs:
    result.add(indent & "    \"" & name & "\" \"" & constraint & "\"\n")
  result.add(indent & "}\n")

proc formatVersion(v: Version, indent: string): string =
  result.add(indent & "version \"" & v.version & "\" {\n")
  result.add(indent & "    content_hash \"" & v.contentHash & "\"\n")
  result.add(formatRequires(v.requires, indent & "    "))
  for prov in v.provenances:
    result.add(formatProvenance(prov, indent & "    "))
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
  ## Emit canonical KDL for an Index. Canonicalizes ordering first
  ## (packages alphabetical, versions descending semver).
  let canon = canonicalize(idx)
  result.add("schema_version " & $canon.schemaVersion & "\n")
  for pkg in canon.packages:
    result.add(formatPackage(pkg))

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

proc parseProvenance(doc: KdlDoc, node: KdlNode): Provenance =
  ## Parse a provenance block. The `kind` child determines the variant;
  ## subsequent fields populate the appropriate branch.
  var kind = pkGit
  for child in node.children:
    if doc.interner.lookup(child.name) == "kind":
      let kindStr = child.entries[0].argValue.strVal
      case kindStr
      of "git": kind = pkGit
      of "oci": kind = pkOci
      else: kind = pkGit  # strict-schema rejection lands in later cycle
      break
  result = Provenance(kind: kind)
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    let value = child.entries[0].argValue.strVal
    case kind
    of pkGit:
      case childName
      of "url":        result.url       = value
      of "ref":        result.gitRef    = value
      of "commit_sha": result.commitSha = value
      else: discard
    of pkOci:
      case childName
      of "registry":   result.registry   = value
      of "repository": result.repository = value
      of "digest":     result.digest     = value
      else: discard

proc parseRequires(doc: KdlDoc, node: KdlNode): OrderedTable[string, string] =
  result = initOrderedTable[string, string]()
  for child in node.children:
    let name = doc.interner.lookup(child.name)
    if child.entries.len >= 1:
      result[name] = child.entries[0].argValue.strVal

proc parseVersion(doc: KdlDoc, node: KdlNode): Version =
  result = Version(
    version: node.entries[0].argValue.strVal,
    requires: initOrderedTable[string, string](),
  )
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    case childName
    of "content_hash": result.contentHash = child.entries[0].argValue.strVal
    of "attestation":  result.attestation = child.entries[0].argValue.strVal
    of "signed_by":    result.signedBy    = child.entries[0].argValue.strVal
    of "published_at": result.publishedAt = child.entries[0].argValue.strVal
    of "provenance":   result.provenances.add(parseProvenance(doc, child))
    of "requires":     result.requires    = parseRequires(doc, child)
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
