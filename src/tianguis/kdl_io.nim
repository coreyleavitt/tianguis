## KDL projection of the tianguis Index data model.
##
## Hand-rolled parse/format against the kdl library's AST primitives.
## Strict schema: unknown nodes / properties raise typed errors with
## stable IDX-* codes ([[error_catalog_discipline]]).

import std/[options, strutils, tables]
import nkdl
import ./model
import ./errors

# Re-export nkdl so consumers calling parseKdl get access to Result's
# .isOk / .get accessors without needing a separate `import nkdl`.
export nkdl, errors

# ---------------------------------------------------------------------------
# Package name validation — single source of truth for all write paths
# ---------------------------------------------------------------------------

proc isValidPackageName*(name: string): bool =
  ## Return true iff `name` is safe to record in index.kdl.
  ##
  ## Rules (must agree with milpa's `is_safe_name` on the read side):
  ##   1. Non-empty.
  ##   2. Only chars from the strict allowlist [A-Za-z0-9_.-].
  ##   3. No leading `.` (rejects `.git`, `.`, `..`, `.hidden`).
  ##   4. No `..` sequence anywhere (rejects `a..b`, `..`).
  ##   5. Not exactly `.` or `..` (belt-and-suspenders over rule 3/4 above).
  ##
  ## Rules 3-5 close the registry-wide DoS: milpa's `_validate_safe_name`
  ## hard-errors on `..` in a name, making index.kdl unparseable for EVERY
  ## consumer if a `..`-named entry lands. The allowlist charset (rule 2) is
  ## the primary gate; `/` and `\` are already blocked by it.
  if name.len == 0: return false
  # Rule 3 — no leading dot.
  if name[0] == '.': return false
  # Rule 2 — allowlist charset only.
  for c in name:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-'}:
      return false
  # Rule 4 — no `..` sequence anywhere (catches `a..b` and `..`).
  if ".." in name: return false
  true

# ---------------------------------------------------------------------------
# KDL string escaping
# ---------------------------------------------------------------------------

proc kdlEscapeString*(s: string): string =
  ## Escape a string for embedding inside a KDL quoted string literal.
  ##
  ## Mirrors the escape policy in nkdl's `appendQuotedString` (emitter.nim):
  ##   - `\` → `\\`
  ##   - `"` → `\"`
  ##   - newline (U+000A) → `\n`
  ##   - carriage return (U+000D) → `\r`
  ##   - tab (U+0009) → `\t`
  ##   - backspace (U+0008) → `\b`
  ##   - form feed (U+000C) → `\f`
  ##   - other KDL-disallowed control bytes (U+0000–U+0008, U+000E–U+001F,
  ##     U+007F) → `\u{XX}` hex escape
  ##
  ## The caller writes the surrounding `"` delimiters; this proc only
  ## processes the *content* of the string.
  ##
  ## nkdl does not export a standalone string-escape helper (only the
  ## `BufferEmitter`-based push functions), so we mirror the logic here.
  ## This is the single source of truth for KDL escaping in tianguis.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"':  result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\x08': result.add("\\b")  # backspace
    of '\x0c': result.add("\\f")  # form feed
    else:
      let u = uint8(c)
      # KDL-disallowed control bytes: U+0000–U+0008, U+000E–U+001F, U+007F
      if (u <= 0x08'u8) or (u >= 0x0E'u8 and u <= 0x1F'u8) or (u == 0x7F'u8):
        result.add("\\u{")
        const HexDigits = "0123456789abcdef"
        if u < 0x10'u8:
          result.add(HexDigits[int(u)])
        else:
          result.add(HexDigits[int(u shr 4)])
          result.add(HexDigits[int(u and 0x0f)])
        result.add('}')
      else:
        result.add(c)

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

proc formatProvenance(p: Provenance, indent: string): string =
  result.add(indent & "provenance {\n")
  result.add(indent & "    kind \"" & kdlEscapeString($p.kind) & "\"\n")
  case p.kind
  of pkGit:
    result.add(indent & "    url (url)\"" & kdlEscapeString(p.url) & "\"\n")
    result.add(indent & "    ref \"" & kdlEscapeString(p.gitRef) & "\"\n")
    result.add(indent & "    commit_sha \"" & kdlEscapeString(p.commitSha) & "\"\n")
  of pkOci:
    result.add(indent & "    registry \"" & kdlEscapeString(p.registry) & "\"\n")
    result.add(indent & "    repository \"" & kdlEscapeString(p.repository) & "\"\n")
    result.add(indent & "    digest \"" & kdlEscapeString(p.digest) & "\"\n")
    if p.source.len > 0:
      # Optional source git repo this OCI artifact was published from
      # (milpa `publish --output`'s `source_url`, threaded through
      # `add-entry --source`). Omitted when absent — same discipline as
      # rekor/bundle above (no hollow field on the 2600+ existing entries).
      result.add(indent & "    source (url)\"" & kdlEscapeString(p.source) & "\"\n")
  result.add(indent & "}\n")

proc formatRequires(r: OrderedTable[string, string], indent: string): string =
  if r.len == 0: return
  result.add(indent & "requires {\n")
  for name, constraint in r.pairs:
    result.add(indent & "    \"" & kdlEscapeString(name) & "\" \"" & kdlEscapeString(constraint) & "\"\n")
  result.add(indent & "}\n")

proc formatRekor(rk: RekorRef, indent: string): string =
  ## Emit the author-signed Rekor attestation pointer. Only non-empty
  ## sub-fields are written (a publish that captured a logIndex but no UUID
  ## omits `uuid` rather than emitting an empty one). The caller emits this
  ## block only when `Version.rekor` is `some` (milpa-vendored versions have
  ## `none` and produce no block).
  result.add(indent & "rekor {\n")
  if rk.uuid.len > 0:
    result.add(indent & "    uuid \"" & kdlEscapeString(rk.uuid) & "\"\n")
  if rk.logIndex.len > 0:
    result.add(indent & "    log_index \"" & kdlEscapeString(rk.logIndex) & "\"\n")
  if rk.integratedTime.len > 0:
    result.add(indent & "    integrated_time \"" & kdlEscapeString(rk.integratedTime) & "\"\n")
  result.add(indent & "}\n")

proc formatVersion(v: Version, indent: string): string =
  result.add(indent & "version \"" & kdlEscapeString(v.version) & "\" {\n")
  result.add(indent & "    content_hash \"" & kdlEscapeString(v.contentHash) & "\"\n")
  result.add(formatRequires(v.requires, indent & "    "))
  for prov in v.provenances:
    result.add(formatProvenance(prov, indent & "    "))
  result.add(indent & "    attestation \"" & kdlEscapeString(v.attestation) & "\"\n")
  result.add(indent & "    signed_by \"" & kdlEscapeString(v.signedBy) & "\"\n")
  result.add(indent & "    published_at \"" & kdlEscapeString(v.publishedAt) & "\"\n")
  if v.rekor.isSome:
    result.add(formatRekor(v.rekor.get, indent & "    "))
  if v.bundlePin.isSome:
    # Delivery-integrity pin: sha256 of the attestation bundle BYTES, as a
    # property (not a scalar child) — matches milpa's wire format exactly
    # (registry-protocol §3.2 NORMATIVE: `bundle sha256="<64-hex>"`).
    result.add(indent & "    bundle sha256=\"" & kdlEscapeString(v.bundlePin.get) & "\"\n")
  if v.partiallyResolved:
    result.add(indent & "    partially_resolved #true\n")
  result.add(indent & "}\n")

proc formatPackage(pkg: Package): string =
  result.add("package \"" & kdlEscapeString(pkg.name) & "\" {\n")
  result.add("    namespace \"" & kdlEscapeString(pkg.namespace) & "\"\n")
  result.add("    upstream (url)\"" & kdlEscapeString(pkg.upstream) & "\"\n")
  if pkg.authorizedSigner.isSome:
    # Signer-continuity ratchet pin (rfc-attestation-delivery S8 Layer 3):
    # the SAN authorized to author-sign this package. Omitted until the
    # first author-signed version pins it (mergeVendored, vendor/merge.nim).
    result.add("    authorized-signer \"" & kdlEscapeString(pkg.authorizedSigner.get) & "\"\n")
  for v in pkg.versions:
    result.add(formatVersion(v, "    "))
  result.add("}\n")

proc formatKdl*(idx: Index): string =
  ## Emit canonical KDL for an Index. Canonicalizes ordering first
  ## (packages alphabetical, versions descending semver).
  let canon = canonicalize(idx)
  result.add("schema_version " & $canon.schemaVersion & "\n")
  if canon.attestationEpoch.isSome:
    # Root-level ratchet: milpa's `index_ratchet_seam._raw_attestation_epoch`
    # parses this exact node name at the document root (rfc-attestation-
    # delivery S2). Absent when the ratchet has never been set.
    result.add("attestation-epoch \"" & kdlEscapeString(canon.attestationEpoch.get) & "\"\n")
  if canon.attestationEpochCommitment.isSome:
    # D-Watermark pre-epoch set commitment `C` (milpa `epoch_commitment.py`/
    # `epoch_commitment.rs` parse this exact node name at the document root
    # — see model.nim's field doc). Distinct, append-once sibling of
    # `attestation-epoch` above; absent until armed.
    result.add("attestation-epoch-commitment \"" &
      kdlEscapeString(canon.attestationEpochCommitment.get) & "\"\n")
  for pkg in canon.packages:
    result.add(formatPackage(pkg))

# ---------------------------------------------------------------------------
# Parse — strict schema
# ---------------------------------------------------------------------------

const
  TopLevelNodes  = ["schema_version", "attestation-epoch",
                    "attestation-epoch-commitment", "package"]
  PackageChildren = ["namespace", "upstream", "authorized-signer", "version"]
  VersionChildren = [
    "content_hash", "requires", "provenance",
    "attestation", "signed_by", "published_at",
    "rekor", "bundle", "partially_resolved",
  ]
  RekorChildren = ["uuid", "log_index", "integrated_time"]
  ProvenanceChildren = [
    # union of all variant fields — strict-kind enforcement happens
    # post-discrimination
    "kind", "url", "ref", "commit_sha", "registry", "repository", "digest",
    "source",
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
      source:     node.childText("source"),
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

proc parseRekor(doc: KdlDoc, node: KdlNode): Result[RekorRef, IdxError] =
  ## Parse the optional `rekor { uuid; log_index; integrated_time }` block.
  ## Strict membership: any child not in RekorChildren raises IDX-NODE-UNKNOWN.
  for child in node.children:
    if child.name notin RekorChildren:
      return err[RekorRef, IdxError](unknownNode(doc, child, "rekor"))
  ok[RekorRef, IdxError](RekorRef(
    uuid:           node.childText("uuid"),
    logIndex:       node.childText("log_index"),
    integratedTime: node.childText("integrated_time"),
  ))

proc isHex64*(s: string): bool =
  ## True iff `s` is exactly 64 lowercase hex characters — the bundle-pin
  ## wire format (registry-protocol §3.2 NORMATIVE). Single source of truth
  ## for the format on the write side; mirrors milpa's `_RE_HEX64` on read.
  ## Exported so admission paths (e.g. `add-entry --bundle-pin`) validate
  ## against the exact same rule the serializer enforces — no second
  ## regex/allowlist copy (rfc-attestation-delivery S7a).
  if s.len != 64: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

proc parseBundle(doc: KdlDoc, node: KdlNode): Result[string, IdxError] =
  ## Parse the `bundle sha256="<64-hex>"` delivery-integrity pin (a KDL
  ## property, not a scalar child — matches milpa's `node_prop_str(child,
  ## "sha256")`). Strict: tianguis is the producer, so a missing or
  ## malformed `sha256` is rejected outright, unlike milpa's lenient
  ## consumer-side collapse-to-None (a malformed pin must never be written).
  let raw = node.propStr("sha256")
  if raw.isNone or not isHex64(raw.get):
    let (line, col) = doc.lineMap.lineColOf(node.span.offset)
    return err[string, IdxError](initIndexError(
      iecBadType,
      "bundle sha256 must be 64 lowercase hex characters, got " &
        (if raw.isSome: "'" & raw.get & "'" else: "<missing>"),
      line = line, col = col,
    ))
  ok[string, IdxError](raw.get)

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
    of "rekor":
      let rr = parseRekor(doc, child)
      if rr.isErr: return err[Version, IdxError](rr.getErr)
      v.rekor = some(rr.get)
    of "bundle":
      let br = parseBundle(doc, child)
      if br.isErr: return err[Version, IdxError](br.getErr)
      v.bundlePin = some(br.get)
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
    of "authorized-signer":
      pkg.authorizedSigner = some(child.argText)
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
    of "attestation-epoch":
      let epoch = node.argStr(0)
      if epoch.isSome: idx.attestationEpoch = epoch
    of "attestation-epoch-commitment":
      let commitment = node.argStr(0)
      if commitment.isSome: idx.attestationEpochCommitment = commitment
    of "package":
      let pr = parsePackage(doc, node)
      if pr.isErr: return err[Index, IdxError](pr.getErr)
      idx.packages.add(pr.get)
    else: discard  # caught by `notin` above
  ok[Index, IdxError](idx)
