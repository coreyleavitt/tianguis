## KDL projection of the tianguis Index data model.
##
## Hand-rolled parse/format against the kdl library's AST primitives.
## Strict schema: unknown nodes / properties raise typed errors with
## stable IDX-* codes ([[error_catalog_discipline]]).

import std/[options, tables]
import nkdl
import ./model
import ./errors

# Re-export nkdl so consumers calling parseKdl get access to Result's
# .isOk / .get accessors without needing a separate `import nkdl`.
export nkdl, errors

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
  if v.partiallyResolved:
    result.add(indent & "    partially_resolved #true\n")
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
    "partially_resolved",
  ]
  ProvenanceChildren = [
    # union of all variant fields — strict-kind enforcement happens
    # post-discrimination
    "kind", "url", "ref", "commit_sha", "registry", "repository", "digest",
  ]

# Bridge helpers — the canonical typed↔DOM escape-hatch pattern. The
# schema is "scalar as named child node" (`name "value"`); these read the
# single positional arg of a node, tolerating absence with "" (the lenient
# default the prior interned-AST path also produced).
proc argText(n: KdlNode, i = 0): string =
  ## Positional arg `i` as a string, or "" if the node/arg is absent or
  ## non-string.
  if n.isNil: "" else: n.argStr(i).get("")

proc childText(n: KdlNode, name: string): string =
  ## Scalar-child accessor: the first arg of the `name "value"` child, or "".
  n.child(name).argText

proc unknownNode(doc: KdlDoc, node: KdlNode, ctx: string): IdxError =
  let (line, col) = doc.lineMap.lineColOf(node.span.offset)
  initIndexError(
    iecUnknownNode,
    "unknown node '" & node.name & "' in " & ctx,
    line = line, col = col,
  )

proc parseProvenance(doc: KdlDoc, node: KdlNode): Result[Provenance, IdxError] =
  # Strict membership first (union of all variant fields); kind-specific
  # enforcement is post-discrimination, matching the prior behavior.
  for child in node.children:
    if child.name notin ProvenanceChildren:
      return err[Provenance, IdxError](unknownNode(doc, child, "provenance"))
  case node.childText("kind")
  of "git", "":   # absent `kind` defaults to git (prior behavior)
    ok[Provenance, IdxError](Provenance(
      kind:      pkGit,
      url:       node.childText("url"),
      gitRef:    node.childText("ref"),
      commitSha: node.childText("commit_sha"),
    ))
  of "oci":
    ok[Provenance, IdxError](Provenance(
      kind:       pkOci,
      registry:   node.childText("registry"),
      repository: node.childText("repository"),
      digest:     node.childText("digest"),
    ))
  else:
    let anchor = node.child("kind")
    let (line, col) = doc.lineMap.lineColOf(
      (if anchor.isNil: node else: anchor).span.offset)
    err[Provenance, IdxError](initIndexError(
      iecBadType,
      "unknown provenance kind '" & node.childText("kind") & "'",
      line = line, col = col,
    ))

proc parseRequires(node: KdlNode): OrderedTable[string, string] =
  ## A `requires` block: each child is `<dep-name> "<constraint>"` — the
  ## node name is the map key (dynamic-name map shape).
  result = initOrderedTable[string, string]()
  for child in node.children:
    let v = child.argStr(0)
    if v.isSome: result[child.name] = v.get

proc parseVersion(doc: KdlDoc, node: KdlNode): Result[Version, IdxError] =
  var v = Version(
    version: node.argText,
    requires: initOrderedTable[string, string](),
  )
  for child in node.children:
    if child.name notin VersionChildren:
      return err[Version, IdxError](unknownNode(doc, child, "version"))
    case child.name
    of "content_hash":       v.contentHash       = child.argText
    of "attestation":        v.attestation        = child.argText
    of "signed_by":          v.signedBy           = child.argText
    of "published_at":       v.publishedAt        = child.argText
    of "partially_resolved": v.partiallyResolved  = child.argBool(0).get(false)
    of "provenance":
      let pr = parseProvenance(doc, child)
      if pr.isErr: return err[Version, IdxError](pr.getErr)
      v.provenances.add(pr.get)
    of "requires":           v.requires           = parseRequires(child)
    else: discard  # caught by `notin` check above
  ok[Version, IdxError](v)

proc parsePackage(doc: KdlDoc, node: KdlNode): Result[Package, IdxError] =
  var pkg = Package(name: node.argText)
  for child in node.children:
    if child.name notin PackageChildren:
      return err[Package, IdxError](unknownNode(doc, child, "package"))
    case child.name
    of "namespace": pkg.namespace = child.argText
    of "upstream":  pkg.upstream  = child.argText
    of "version":
      let vr = parseVersion(doc, child)
      if vr.isErr: return err[Package, IdxError](vr.getErr)
      pkg.versions.add(vr.get)
    else: discard  # caught by `notin` above
  ok[Package, IdxError](pkg)

proc parseKdl*(s: string): Result[Index, IdxError] =
  ## Parse canonical KDL into an Index. Strict schema: any node not in the
  ## allowed set raises IDX-NODE-UNKNOWN.
  let parsed = parse(s)
  if parsed.isErr:
    let pe = parsed.getErr.enriched(s, "<input>")
    return err[Index, IdxError](initIndexError(
      iecKdlParse, "KDL parse error",
      line = pe.line, col = pe.col,
    ))

  let doc = parsed.get
  var idx = Index(schemaVersion: 0, packages: @[])
  for node in doc.nodes:
    if node.name notin TopLevelNodes:
      return err[Index, IdxError](unknownNode(doc, node, "top-level"))
    case node.name
    of "schema_version":
      idx.schemaVersion = node.argInt(0).get(0).int
    of "package":
      let pr = parsePackage(doc, node)
      if pr.isErr: return err[Index, IdxError](pr.getErr)
      idx.packages.add(pr.get)
    else: discard  # caught by `notin` above
  ok[Index, IdxError](idx)
