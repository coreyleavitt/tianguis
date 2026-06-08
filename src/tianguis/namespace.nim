## Namespace derivation — the identity-equality function for tianguis packages.
##
## `deriveNamespace(url)` is the **single source of truth** for how a raw
## upstream URL maps to a `(host, org)` ForgeRef. Used by:
##   - vendor bot at ingest (stamps identity on every version)
##   - author-signed path (validates OIDC identity against provenance)
##   - immutability guard (re-derives to check stored identity is stable)
##
## Spec: docs/rfc-package-identity.md § "Namespace canonicalization (NORMATIVE)"
##
## Algorithm: structured parse → normalize → serialize, NOT string surgery.
## Three-language implementations (Nim + Python + future Rust) agree by sharing
## the S2 conformance corpus, not by copying string-mangling logic.

import std/[strutils, options]
import nkdl  # for Result[T,E], ok(), err()
import ./model

# Re-export so callers get Result accessors without a separate import.
export nkdl

type
  ForgeRef* = object
    host*: string   ## e.g. "github.com"
    org*:  string   ## e.g. "coreyleavitt" or "~SomeUser"

  DerivationError* = enum
    derrUnparseable       ## no usable host/path could be parsed
    derrNoOrg             ## parsed to a bare host with no org segment
    derrGitlabNestedGroup ## gitlab path depth > 2 (filed #37)

proc namespaceString*(f: ForgeRef): string =
  ## Serialize a ForgeRef as "host/org".
  f.host & "/" & f.org

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc percentDecode(s: string): string =
  ## Percent-decode a single path segment (RFC 3986).
  ## Only decodes well-formed `%XX` sequences; leaves bare `%` verbatim.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let hi = s[i + 1]
      let lo = s[i + 2]
      if hi in HexDigits and lo in HexDigits:
        let val = parseHexInt($hi & $lo)
        result.add(char(val))
        i += 3
        continue
    result.add(s[i])
    inc i

type CasePolicy = enum
  cpFold     ## lowercase the org (case-insensitive forge)
  cpPreserve ## keep verbatim (case-sensitive forge)

proc forgePolicy(host: string): (int, CasePolicy) =
  ## Return (org-segment-count, case-policy) for a normalized host.
  ## All known forges use 1 org segment; fallback also uses 1 with preserve.
  case host
  of "github.com":    (1, cpFold)
  of "gitlab.com":    (1, cpFold)
  of "bitbucket.org": (1, cpFold)
  of "codeberg.org":  (1, cpPreserve)
  of "git.sr.ht":     (1, cpPreserve)
  else:               (1, cpPreserve)

proc normalizeHost(raw: string): string =
  ## Strip leading "www.", lowercase, strip trailing ".".
  var h = raw.toLowerAscii()
  if h.startsWith("www."):
    h = h[4 .. ^1]
  if h.endsWith("."):
    h = h[0 .. ^2]
  h

# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------

type ParsedUrl = object
  host:     string
  segments: seq[string]   ## path segments, already split on '/'

proc parseRawUrl(raw: string): Option[ParsedUrl] =
  ## Extract (host, pathSegments) from a raw URL string.
  ## Returns none if no host can be identified.
  var rest = raw

  # 1. SSH short form: git@host:path (no scheme, colon as delimiter)
  #    Detect by: no "://" AND contains '@' followed eventually by ':'
  if not rest.contains("://"):
    let atPos = rest.find('@')
    if atPos >= 0:
      # Could be git@host:path/to/repo
      let afterAt = rest[atPos + 1 .. ^1]
      let colonPos = afterAt.find(':')
      if colonPos > 0:
        let host = afterAt[0 ..< colonPos]
        let path = afterAt[colonPos + 1 .. ^1]
        var segs: seq[string] = @[]
        for s in path.split('/'):
          if s.len > 0:
            segs.add(percentDecode(s))
        if segs.len > 0:
          # Strip .git from final segment
          if segs[^1].endsWith(".git"):
            segs[^1] = segs[^1][0 .. ^5]
        return some(ParsedUrl(host: host, segments: segs))
    return none(ParsedUrl)

  # 2. Scheme-based URL
  # Strip known schemes
  for scheme in ["https://", "http://", "git://", "ssh://"]:
    if rest.startsWith(scheme):
      rest = rest[scheme.len .. ^1]
      break

  # Drop userinfo@ if present (e.g. "git@" left over from ssh://git@host/...)
  let atPos = rest.find('@')
  let slashPos = rest.find('/')
  if atPos >= 0 and (slashPos < 0 or atPos < slashPos):
    rest = rest[atPos + 1 .. ^1]

  # Drop port, query, fragment — find the authority (host[:port]) end
  # The authority ends at the first '/', '?', or '#'
  var authorityEnd = rest.len
  for i, c in rest:
    if c in {'/', '?', '#'}:
      authorityEnd = i
      break
  let authority = rest[0 ..< authorityEnd]
  let pathStr = if authorityEnd < rest.len: rest[authorityEnd .. ^1] else: ""

  # Strip port from authority
  var host = authority
  let portColon = host.rfind(':')
  if portColon >= 0:
    let possiblePort = host[portColon + 1 .. ^1]
    # Only strip if it's actually digits (i.e. a port, not part of IPv6 or host)
    var isPort = possiblePort.len > 0
    for c in possiblePort:
      if c notin Digits:
        isPort = false
        break
    if isPort:
      host = host[0 ..< portColon]

  if host.len == 0:
    return none(ParsedUrl)

  # Strip query (?) and fragment (#) from pathStr before splitting.
  # The authority split above handles ? and # that appear immediately after
  # the host, but a URL like https://custom-forge.io/org?tenant=x/sub has
  # the ? INSIDE the path string, not at the start. Truncate at first ? or #.
  var cleanPath = pathStr
  for i, c in cleanPath:
    if c == '?' or c == '#':
      cleanPath = cleanPath[0 ..< i]
      break

  # Parse path into segments, percent-decoding each, dropping empties
  var segs: seq[string] = @[]
  for s in cleanPath.split('/'):
    if s.len > 0:
      segs.add(percentDecode(s))

  # Strip .git from final segment
  if segs.len > 0 and segs[^1].endsWith(".git"):
    segs[^1] = segs[^1][0 .. ^5]
    # If stripping .git left an empty segment, drop it
    if segs[^1].len == 0:
      segs.setLen(segs.len - 1)

  some(ParsedUrl(host: host, segments: segs))


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

type
  RepoRef* = object
    ## A fully-parsed forge reference, including the repo segment.
    ## Used when the caller needs to discriminate at the repo level
    ## (e.g. intra-org leaf collision detection).
    host*: string   ## e.g. "github.com"
    org*:  string   ## e.g. "coreyleavitt"
    repo*: string   ## e.g. "nimkdl" (stripped .git; "" if no repo segment)

type
  IdentityDrift* = object
    ## Signals that a re-derived namespace does not match the stored one.
    ## Distinct from the content-hash DriftAlert (merge.nim): this is
    ## identity stability, not content stability. Per spec commitment #8,
    ## the stored namespace is authoritative; a drift here means something
    ## changed in the provenance (rename, org move, forge migration) that
    ## MUST NOT silently overwrite the recorded identity.
    name*:               string
    storedNamespace*:    string
    rederivedNamespace*: string

proc checkIdentityStable*(
    name, stored, rederived: string): Option[IdentityDrift] =
  ## Returns `some(IdentityDrift)` when stored != rederived; `none` when they match.
  ## Pure function — no side effects; wired into re-ingest by S4.
  if stored == rederived:
    none(IdentityDrift)
  else:
    some(IdentityDrift(
      name:               name,
      storedNamespace:    stored,
      rederivedNamespace: rederived,
    ))

# ---------------------------------------------------------------------------
# Internal: single URL → RepoRef parser (shared by deriveNamespace + deriveRepo)
# ---------------------------------------------------------------------------

proc parseToRepoRef(raw: string): Result[RepoRef, DerivationError] =
  ## Parse a raw URL into a fully-qualified RepoRef (host, org, repo).
  ## This is the SINGLE source of parsing logic; both deriveNamespace and
  ## deriveRepo delegate here so there is exactly one parser.
  let parsed = parseRawUrl(raw)
  if parsed.isNone:
    return err[RepoRef, DerivationError](derrUnparseable)

  let p = parsed.get
  let host = normalizeHost(p.host)
  let segs = p.segments

  if segs.len == 0:
    return err[RepoRef, DerivationError](derrNoOrg)

  let (orgCount, policy) = forgePolicy(host)

  # GitLab nested-group check: if path depth > 2 (more than org + repo),
  # that's a nested group — rejected until #37 lands.
  if host == "gitlab.com" and segs.len > 2:
    return err[RepoRef, DerivationError](derrGitlabNestedGroup)

  # Take the first `orgCount` segments as the org.
  # (Currently always 1 for all known forges + fallback.)
  if segs.len < orgCount:
    return err[RepoRef, DerivationError](derrNoOrg)

  var org = segs[0 ..< orgCount].join("/")

  # Apply case policy
  case policy
  of cpFold:    org = org.toLowerAscii()
  of cpPreserve: discard   # keep verbatim

  # Repo segment: the path segment after the org (if present).
  # Percent-decode and .git-stripping already done in parseRawUrl.
  let repo = if segs.len > orgCount: segs[orgCount] else: ""

  ok[RepoRef, DerivationError](RepoRef(host: host, org: org, repo: repo))

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc deriveRepo*(raw: string): Result[RepoRef, DerivationError] =
  ## Parse a raw upstream URL into a `RepoRef` — the fully-qualified
  ## (host, org, repo) triple. Used for intra-org leaf collision detection
  ## where the repo segment is needed to discriminate two repos under the
  ## same org.
  ##
  ## Shares the same parsing logic as `deriveNamespace`; there is ONE parser.
  parseToRepoRef(raw)

proc deriveNamespace*(raw: string): Result[ForgeRef, DerivationError] =
  ## Derive a canonical `ForgeRef` from a raw upstream URL.
  ##
  ## Implements the structured parse → normalize → serialize spec from
  ## docs/rfc-package-identity.md § "Namespace canonicalization (NORMATIVE)".
  ## Delegates to the shared parseToRepoRef parser; the repo segment is
  ## deliberately discarded (namespace stops at host/org per the spec).
  parseToRepoRef(raw).map(proc(r: RepoRef): ForgeRef =
    ForgeRef(host: r.host, org: r.org)
  )

proc deriveVersionNamespace*(v: Version): Result[string, DerivationError] =
  ## SSOT per-version anchor rule. First pkGit provenance -> its url; else
  ## signedBy (OIDC SAN); else err(derrUnparseable). `upstream` is NEVER an anchor.
  ##
  ## Discriminant is provenance-presence, NOT the freeform `attestation` string
  ## (legacy entries predate the string constants).
  for prov in v.provenances:
    if prov.kind == pkGit:
      return deriveNamespace(prov.url).map(
        proc(f: ForgeRef): string = namespaceString(f)
      )
  if v.signedBy.len > 0:
    return deriveNamespace(v.signedBy).map(
      proc(f: ForgeRef): string = namespaceString(f)
    )
  err[string, DerivationError](derrUnparseable)
