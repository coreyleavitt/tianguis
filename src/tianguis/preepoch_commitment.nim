## D-Watermark pre-epoch set commitment `C` — the canonical construction
## (milpa `docs/rfc-attestation-v1-normative.md` §6 slice
## **S-EpochCommitment**, decisions D14-D18; spec `registry-protocol.md`
## §3.4.8/§3.4.9).
##
## This is the tianguis (arming/producer) side of the SAME construction
## milpa's `impls/python/milpa/epoch_commitment.py` and
## `impls/rust/crates/milpa-core/src/epoch_commitment.rs` implement on the
## consuming side. **Byte-exact cross-impl parity is the load-bearing
## property of this module**: `commitmentDigest` MUST equal what milpa
## computes for the SAME logical set `S`, or every consumer's
## `EpochCommitmentStatus` collapses to `ArmingInvalid` (`hash(S) != C`) the
## moment a registry arms — see the golden vectors pinned in
## `tests/test_preepoch_commitment.nim`, copied verbatim from milpa's own
## pinned golden vectors (`impls/python/tests/test_epoch_commitment.py`,
## `impls/rust/crates/milpa-core/src/epoch_commitment_tests.rs`).
##
## Canonical construction (spec §3.4.8 NORMATIVE)::
##
##     C = sha256("milpa-preepoch-v1:" ++ canonical_bytes(sorted_deduped(S)))
##
## `sorted_deduped(S)`: exact-duplicate `PreEpochIdentity` records removed
## (structural equality on the 4-tuple), the remainder sorted by:
##   1. `namespace` — lexicographic (byte-wise; coincides with codepoint
##      order for well-formed UTF-8).
##   2. `name` — lexicographic, same rule.
##   3. `version` — semver PRECEDENCE order when the raw string parses
##      (`parseVersionForSort`), NEVER an ad-hoc string sort. An unparseable
##      raw version string sorts AFTER every parseable version (two disjoint
##      buckets, never compared element-wise); unparseable versions among
##      themselves are ordered by raw string.
##   4. `content_hash` — lexicographic, next tiebreak.
##   5. the RAW `version` string — the FINAL tiebreak, making the order
##      TOTAL over the full 4-tuple (without it, `1.0.0` vs `1.0.0+build` —
##      precedence-equal, distinct raw strings — would collide on the sort
##      key, making `C` input-order-dependent).
##
## `canonical_bytes`: each identity record is encoded as
## `namespace & "\x1f" & name & "\x1f" & version & "\x1f" & content_hash`
## (UTF-8) — `\x1f` UNIT SEPARATOR between fields. Records are joined, IN
## SORTED ORDER, by `"\x1e"` RECORD SEPARATOR. An empty `S` encodes as `""`
## (the domain prefix alone).
##
## The `"milpa-preepoch-v1:"` domain-separation prefix (D16 hash hygiene)
## ensures `C` cannot collide with a hash of the same bytes computed for an
## unrelated purpose elsewhere in the system.
##
## ### Version parsing — why this module cannot reuse `model.parseSemverTriple`
##
## `model.parseSemverTriple` is a lenient "best-effort" parser: it never
## fails (malformed input silently becomes `(0, 0, 0)`) and has no
## prerelease/precedence support. That is unsound for THIS construction,
## which requires exact parity with milpa's `version.py::parse_version` —
## specifically its two-bucket "parseable sorts before unparseable" rule and
## full semver 2.0 §11 prerelease precedence. `parseVersionForSort` below is
## a dedicated, hand-rolled parser (no `std/re`/PCRE dependency, matching
## this codebase's existing hand-rolled-parse convention in kdl_io.nim/
## model.nim) that reproduces milpa's `_VERSION_RE` grammar and
## `Version._precedence_key()` exactly:
##
##   `v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?`
##   (full match; optional `v` prefix; each numeric component bounded to
##   u64::MAX, matching milpa's own overflow guard).

import std/[algorithm, hashes, json, options, sequtils, sets, strutils]
import nimcrypto/[hash, sha2]
import ./model

# Deliberately NOT `export json` here: `export` re-exports a module's FULL
# public API regardless of any local `except` filter, and importers of this
# module (cli.nim) also import json_io.nim, which defines its OWN
# `parseJson*(s: string): Result[Index, IdxError]` — re-exporting std/json's
# `parseJson` here would make every such call site ambiguous. Callers that
# need `JsonNode` accessors on `identitiesToJson`'s return value import
# `std/json` themselves (excluding `parseJson` if they also see json_io's,
# same as cli.nim does).

# ---------------------------------------------------------------------------
# Identity — the D16 identity tuple
# ---------------------------------------------------------------------------

type
  PreEpochIdentity* = object
    ## `(namespace, name, version, content_hash)` — the D16 identity tuple.
    ## `namespace` MUST be included: dropping it would let an attacker
    ## publish a byte-for-byte copy of another namespace's package under a
    ## different namespace and free-ride on its pre-epoch (grandfathered)
    ## status via an identical `(name, version, content_hash)` tuple (spec
    ## §3.4.8's REJECTED-attack note).
    namespace*:   string
    name*:        string
    version*:     string
    contentHash*: string

proc hash*(id: PreEpochIdentity): Hash =
  var h: Hash = 0
  h = h !& hash(id.namespace)
  h = h !& hash(id.name)
  h = h !& hash(id.version)
  h = h !& hash(id.contentHash)
  result = !$h

# ---------------------------------------------------------------------------
# Version precedence parsing — mirrors milpa version.py's _VERSION_RE /
# _parse_numeric_component / _parse_pre_identifiers / _precedence_key
# ---------------------------------------------------------------------------

const U64Max = high(uint64)

type
  PreIdKind = enum pikNum, pikStr
  PreId = object
    case kind: PreIdKind
    of pikNum: numVal: uint64
    of pikStr: strVal: string

  ParsedVersion = object
    major, minor, patch: uint64
    pre: seq[PreId]  ## empty == release

proc parseU64Component(digits: string): Option[uint64] =
  ## Parse an all-digit run into a `uint64`, rejecting overflow past
  ## `u64::MAX` — mirrors milpa's `_parse_numeric_component` overflow guard
  ## (cross-impl parity: a value that overflows u64 in Rust must also fail
  ## to parse here, not silently wrap).
  if digits.len == 0: return none(uint64)
  var value: uint64 = 0
  for c in digits:
    let d = uint64(ord(c) - ord('0'))
    if value > (U64Max - d) div 10'u64:
      return none(uint64)
    value = value * 10'u64 + d
  some(value)

proc isAllDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

proc parsePreIdentifier(part: string): PreId =
  ## Per semver 2.0: an identifier consisting entirely of digits is parsed
  ## as a numeric id (compared numerically); others stay alphanumeric.
  ## Mirrors milpa's `_parse_pre_identifiers`: an all-digit identifier that
  ## overflows u64 falls back to the alphanumeric (string) form rather than
  ## raising, so parsing stays total.
  if isAllDigits(part):
    let n = parseU64Component(part)
    if n.isSome:
      return PreId(kind: pikNum, numVal: n.get)
  PreId(kind: pikStr, strVal: part)

proc isIdChar(c: char): bool =
  c in {'0'..'9', 'A'..'Z', 'a'..'z', '-'}

proc consumeDigits(s: string, pos: var int): string =
  let start = pos
  while pos < s.len and s[pos] in {'0'..'9'}: inc pos
  s[start ..< pos]

proc consumeDottedIdentifierRun(s: string, pos: var int): bool =
  ## Consume `[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*` starting at `pos`, advancing
  ## `pos` past the match. Returns false (leaving `pos` unmoved) if the
  ## first group is empty. A trailing `.` NOT followed by a non-empty group
  ## is left unconsumed (mirrors the regex engine backtracking away from
  ## that dot rather than accepting a match with an empty group) — this
  ## matters for a boundary like `-a.` immediately followed by end-of-string
  ## or `+`, where the dot must NOT be swallowed into the prerelease group.
  let g1start = pos
  while pos < s.len and isIdChar(s[pos]): inc pos
  if pos == g1start: return false
  while pos < s.len and s[pos] == '.':
    let save = pos
    inc pos
    let gstart = pos
    while pos < s.len and isIdChar(s[pos]): inc pos
    if pos == gstart:
      pos = save
      break
  true

proc parseVersionForSort(rawText: string): Option[ParsedVersion] =
  ## Hand-rolled equivalent of milpa's
  ## `re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z\-]+(?:\.[0-9A-Za-z\-]+)*))?"
  ## r"(?:\+([0-9A-Za-z\-]+(?:\.[0-9A-Za-z\-]+)*))?\Z")` applied to
  ## `text.strip()` — full match required (trailing/leading junk rejects).
  let text = strip(rawText)
  var pos = 0
  var s = text
  if s.len > 0 and s[0] == 'v':
    s = s[1 ..< s.len]

  let majorStr = consumeDigits(s, pos)
  if majorStr.len == 0: return none(ParsedVersion)
  if pos >= s.len or s[pos] != '.': return none(ParsedVersion)
  inc pos
  let minorStr = consumeDigits(s, pos)
  if minorStr.len == 0: return none(ParsedVersion)
  if pos >= s.len or s[pos] != '.': return none(ParsedVersion)
  inc pos
  let patchStr = consumeDigits(s, pos)
  if patchStr.len == 0: return none(ParsedVersion)

  var preStr = ""
  var buildStr = ""
  if pos < s.len and s[pos] == '-':
    inc pos
    let start = pos
    if not consumeDottedIdentifierRun(s, pos): return none(ParsedVersion)
    preStr = s[start ..< pos]
  if pos < s.len and s[pos] == '+':
    inc pos
    let start = pos
    if not consumeDottedIdentifierRun(s, pos): return none(ParsedVersion)
    buildStr = s[start ..< pos]
  discard buildStr  # build metadata is parsed (matched) but ignored for precedence

  if pos != s.len: return none(ParsedVersion)  # trailing junk: no full match

  let major = parseU64Component(majorStr)
  let minor = parseU64Component(minorStr)
  let patch = parseU64Component(patchStr)
  if major.isNone or minor.isNone or patch.isNone: return none(ParsedVersion)

  var pre: seq[PreId] = @[]
  if preStr.len > 0:
    for part in preStr.split('.'):
      pre.add(parsePreIdentifier(part))

  some(ParsedVersion(major: major.get, minor: minor.get, patch: patch.get, pre: pre))

proc cmpU64(a, b: uint64): int =
  if a < b: -1 elif a > b: 1 else: 0

proc preIdCmp(a, b: PreId): int =
  ## Numeric identifiers always sort before alphanumeric ones (semver 2.0
  ## §11.4.3); mirrors milpa's `(0, n)` / `(1, s)` tagging.
  if a.kind != b.kind:
    if a.kind == pikNum: return -1
    else: return 1
  case a.kind
  of pikNum: cmpU64(a.numVal, b.numVal)
  of pikStr: cmp(a.strVal, b.strVal)

proc precedenceCmp(a, b: ParsedVersion): int =
  ## `Version._precedence_key()`: `(major, minor, patch, isRelease, pre)`
  ## where `isRelease` is 1 for a release (no `pre`) and 0 otherwise — a
  ## release outranks any prerelease of the same major.minor.patch.
  if a.major != b.major: return cmpU64(a.major, b.major)
  if a.minor != b.minor: return cmpU64(a.minor, b.minor)
  if a.patch != b.patch: return cmpU64(a.patch, b.patch)
  let aRel = if a.pre.len == 0: 1 else: 0
  let bRel = if b.pre.len == 0: 1 else: 0
  if aRel != bRel: return cmp(aRel, bRel)
  let n = min(a.pre.len, b.pre.len)
  for i in 0 ..< n:
    let c = preIdCmp(a.pre[i], b.pre[i])
    if c != 0: return c
  cmp(a.pre.len, b.pre.len)

proc versionSortCmp(aRaw, bRaw: string): int =
  ## The two-bucket rule: parseable versions sort before unparseable ones
  ## (the buckets are never compared element-wise); within a bucket, compare
  ## by precedence (parseable) or raw string (unparseable).
  let pa = parseVersionForSort(aRaw)
  let pb = parseVersionForSort(bRaw)
  if pa.isSome and pb.isSome:
    precedenceCmp(pa.get, pb.get)
  elif pa.isSome:
    -1
  elif pb.isSome:
    1
  else:
    cmp(aRaw, bRaw)

# ---------------------------------------------------------------------------
# sorted_deduped + canonical encoding (D16/D17)
# ---------------------------------------------------------------------------

proc identityCmp(a, b: PreEpochIdentity): int =
  if a.namespace != b.namespace: return cmp(a.namespace, b.namespace)
  if a.name != b.name: return cmp(a.name, b.name)
  let vc = versionSortCmp(a.version, b.version)
  if vc != 0: return vc
  if a.contentHash != b.contentHash: return cmp(a.contentHash, b.contentHash)
  cmp(a.version, b.version)  # final tiebreak: raw version string

proc sortedDeduped*(identities: seq[PreEpochIdentity]): seq[PreEpochIdentity] =
  ## Exact-duplicate removal (structural equality on the full 4-tuple,
  ## first occurrence kept — stable) + the D16/§3.4.8 sort order.
  var seen = initHashSet[PreEpochIdentity]()
  result = @[]
  for id in identities:
    if id notin seen:
      seen.incl(id)
      result.add(id)
  result.sort(identityCmp)

const
  FieldSep = "\x1f"
  RecordSep = "\x1e"
  DomainPrefix = "milpa-preepoch-v1:"

proc encodeIdentity(id: PreEpochIdentity): string =
  id.namespace & FieldSep & id.name & FieldSep & id.version & FieldSep & id.contentHash

proc canonicalBytes*(identities: seq[PreEpochIdentity]): string =
  ## `sorted_deduped(S)` encoded per the module doc's "Canonical
  ## construction" — NOT including the domain-separation prefix (see
  ## `canonicalPreimage` for the full preimage).
  let ordered = sortedDeduped(identities)
  ordered.mapIt(encodeIdentity(it)).join(RecordSep)

proc canonicalPreimage*(identities: seq[PreEpochIdentity]): string =
  ## The full `C` preimage: domain prefix ++ `canonicalBytes(S)`.
  DomainPrefix & canonicalBytes(identities)

proc commitmentDigest*(identities: seq[PreEpochIdentity]): string =
  ## `C = sha256(canonicalPreimage(S))` — lowercase hex, 64 chars.
  toLowerAscii($sha256.digest(canonicalPreimage(identities)))

# ---------------------------------------------------------------------------
# Enumeration from the current index (the "grandfather-all" F-op) + sidecar
# JSON wire encoding (spec §3.4.9: `{"identities": [...], "bundle": {...}}`)
# ---------------------------------------------------------------------------

proc enumerateCurrentSet*(idx: Index): seq[PreEpochIdentity] =
  ## Every `(namespace, name, version, content_hash)` identity present in
  ## `idx` at re-arm time — the grandfather-all `S` a fresh arming commits
  ## to (milpa RFC §6 S-EpochCommitment F-op: every entry that exists when
  ## the commitment is minted becomes pre-epoch/grandfathered by definition).
  result = @[]
  for pkg in idx.packages:
    for v in pkg.versions:
      result.add(PreEpochIdentity(
        namespace: pkg.namespace, name: pkg.name,
        version: v.version, contentHash: v.contentHash,
      ))

proc identitiesToJson*(identities: seq[PreEpochIdentity]): JsonNode =
  ## Canonical (sorted+deduped) JSON array of identity objects — the
  ## `identities` field of the `.epoch-commitment` sidecar payload (spec
  ## §3.4.9), matching milpa's `parse_sidecar_payload` wire shape exactly:
  ## `{"namespace": ..., "name": ..., "version": ..., "content_hash": ...}`.
  result = newJArray()
  for id in sortedDeduped(identities):
    result.add(%*{
      "namespace":    id.namespace,
      "name":         id.name,
      "version":      id.version,
      "content_hash": id.contentHash,
    })
