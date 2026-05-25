## KDL projection of the tianguis Index data model.
##
## Hand-rolled parse/format against the kdl library's AST primitives.
## Strict schema: unknown nodes / properties raise typed errors with
## stable IDX-* codes ([[error_catalog_discipline]]).

import std/tables
import kdl
import ./model
import ./errors

# Re-export kdl so consumers calling parseKdl get access to Result's
# .isOk / .get accessors without needing a separate `import kdl`.
export kdl, errors

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
# Parse — strict schema
# ---------------------------------------------------------------------------

const
  TopLevelNodes  = ["schema_version", "package"]
  PackageChildren = ["namespace", "upstream", "version"]
  VersionChildren = [
    "content_hash", "requires", "provenance",
    "attestation", "signed_by", "published_at",
  ]
  ProvenanceChildren = [
    # union of all variant fields — strict-kind enforcement happens
    # post-discrimination
    "kind", "url", "ref", "commit_sha", "registry", "repository", "digest",
  ]

proc unknownNode(doc: KdlDoc, node: KdlNode, ctx: string): IdxError =
  let name = doc.interner.lookup(node.name)
  initIndexError(
    iecUnknownNode,
    "unknown node '" & name & "' in " & ctx,
    line = node.span.start.line, col = node.span.start.col,
  )

proc parseProvenance(doc: KdlDoc, node: KdlNode): Result[Provenance, IdxError] =
  var kind = pkGit
  for child in node.children:
    if doc.interner.lookup(child.name) == "kind":
      let kindStr = child.entries[0].argValue.strVal
      case kindStr
      of "git": kind = pkGit
      of "oci": kind = pkOci
      else:
        return err[Provenance, IdxError](initIndexError(
          iecBadType,
          "unknown provenance kind '" & kindStr & "'",
          line = child.span.start.line, col = child.span.start.col,
        ))
      break
  var prov = Provenance(kind: kind)
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    if childName notin ProvenanceChildren:
      return err[Provenance, IdxError](unknownNode(doc, child, "provenance"))
    let value = if child.entries.len > 0: child.entries[0].argValue.strVal else: ""
    case kind
    of pkGit:
      case childName
      of "url":        prov.url       = value
      of "ref":        prov.gitRef    = value
      of "commit_sha": prov.commitSha = value
      else: discard  # kind already consumed; other kinds' fields ignored
    of pkOci:
      case childName
      of "registry":   prov.registry   = value
      of "repository": prov.repository = value
      of "digest":     prov.digest     = value
      else: discard
  ok[Provenance, IdxError](prov)

proc parseRequires(doc: KdlDoc, node: KdlNode): OrderedTable[string, string] =
  result = initOrderedTable[string, string]()
  for child in node.children:
    let name = doc.interner.lookup(child.name)
    if child.entries.len >= 1:
      result[name] = child.entries[0].argValue.strVal

proc parseVersion(doc: KdlDoc, node: KdlNode): Result[Version, IdxError] =
  var v = Version(
    version: node.entries[0].argValue.strVal,
    requires: initOrderedTable[string, string](),
  )
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    if childName notin VersionChildren:
      return err[Version, IdxError](unknownNode(doc, child, "version"))
    case childName
    of "content_hash": v.contentHash = child.entries[0].argValue.strVal
    of "attestation":  v.attestation = child.entries[0].argValue.strVal
    of "signed_by":    v.signedBy    = child.entries[0].argValue.strVal
    of "published_at": v.publishedAt = child.entries[0].argValue.strVal
    of "provenance":
      let pr = parseProvenance(doc, child)
      if pr.isErr: return err[Version, IdxError](pr.getErr)
      v.provenances.add(pr.get)
    of "requires":     v.requires    = parseRequires(doc, child)
    else: discard  # caught by `notin` check above
  ok[Version, IdxError](v)

proc parsePackage(doc: KdlDoc, node: KdlNode): Result[Package, IdxError] =
  var pkg = Package(name: node.entries[0].argValue.strVal)
  for child in node.children:
    let childName = doc.interner.lookup(child.name)
    if childName notin PackageChildren:
      return err[Package, IdxError](unknownNode(doc, child, "package"))
    case childName
    of "namespace": pkg.namespace = child.entries[0].argValue.strVal
    of "upstream":  pkg.upstream  = child.entries[0].argValue.strVal
    of "version":
      let vr = parseVersion(doc, child)
      if vr.isErr: return err[Package, IdxError](vr.getErr)
      pkg.versions.add(vr.get)
    else: discard  # caught by `notin` above
  ok[Package, IdxError](pkg)

proc parseKdl*(s: string): Result[Index, IdxError] =
  ## Parse canonical KDL into an Index. Strict schema: any node or
  ## property not in the allowed set raises IDX-NODE-UNKNOWN.
  let doc = parse(s)
  if doc.isErr:
    let pe = doc.getErr
    return err[Index, IdxError](initIndexError(
      iecKdlParse, "KDL parse error",
      line = pe.span.start.line, col = pe.span.start.col,
    ))

  var idx = Index(schemaVersion: 0, packages: @[])
  let parsed = doc.get
  for node in parsed.nodes:
    let name = parsed.interner.lookup(node.name)
    if name notin TopLevelNodes:
      return err[Index, IdxError](unknownNode(parsed, node, "top-level"))
    case name
    of "schema_version":
      idx.schemaVersion = node.entries[0].argValue.intVal.int
    of "package":
      let pr = parsePackage(parsed, node)
      if pr.isErr: return err[Index, IdxError](pr.getErr)
      idx.packages.add(pr.get)
    else: discard  # caught by `notin` above
  ok[Index, IdxError](idx)
