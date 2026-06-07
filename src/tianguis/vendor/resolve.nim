## Bare→qualified require resolution for vendored packages.
##
## Translates raw `requires` entries from packages.json / .nimble files
## into fully-qualified `(namespace, name)` pairs using the packages.json
## upstream index as a lookup table.
##
## Three cases (per rfc-package-identity.md S5):
##
##   1. **Bare name present in packages.json index** — look up the URL,
##      derive `host/org` via `deriveNamespace`, produce
##      `ResolvedRequire(namespace, name, constraint)`.
##      If the looked-up URL fails derivation → treat as unresolved.
##
##   2. **URL require** (starts with a scheme or contains "://", or is
##      an SSH git@ form) — self-qualify: `deriveRepo` gives `(host, org, repo)`;
##      produce `ResolvedRequire(namespace=host/org, name=repo, constraint)`.
##      NOTE: `repo` is the URL path's final segment, which is usually but not
##      always the upstream's canonical Nimble package name (the true name is
##      the `.nimble` filename, not knowable without a clone). Callers that need
##      the authoritative name must clone; this is a best-effort approximation.
##
##   3. **Bare name absent** from the index (and not a URL) → unresolved.
##      The name is added to `RequireResolution.unresolved`; the constraint
##      is dropped (the name alone is sufficient for a caller to act on).
##
## Scope: pure mapping only.  No I/O, no cloning, no model persistence.
## The caller (rfc-index-deps) wires `partiallyResolved` onto Version and
## persists the resolved edge list; that is NOT this module's job.

import std/[options, strutils, tables]
import ../namespace
import ./upstream

export namespace, upstream

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ResolvedRequire* = object
    namespace*:  string   ## host/org   e.g. "github.com/status-im"
    name*:       string   ## leaf name  e.g. "nim-chronos"
    constraint*: string   ## carried verbatim from the source requires entry

  RequireResolution* = object
    resolved*:   seq[ResolvedRequire]   ## entries that mapped to a qualified pair
    unresolved*: seq[string]            ## bare names absent from the index (constraint dropped)

  PackagesIndex* = Table[string, string]   ## bare name → upstream URL

# ---------------------------------------------------------------------------
# Build the lookup table from a seq[UpstreamPackage]
# ---------------------------------------------------------------------------

proc buildPackagesIndex*(pkgs: seq[UpstreamPackage]): PackagesIndex =
  ## Build a bare-name → URL lookup from a parsed packages.json list.
  ## Only "git" method entries are included; others are silently skipped
  ## (milpa currently only vends git-fetched packages).
  result = initTable[string, string]()
  for pkg in pkgs:
    if pkg.`method` == "git" and pkg.name.len > 0:
      result[pkg.name] = pkg.url

# ---------------------------------------------------------------------------
# URL detection
# ---------------------------------------------------------------------------

proc looksLikeUrl(s: string): bool =
  ## Heuristic: treat `s` as a URL if it contains "://" (scheme-based) or
  ## starts with "git@" (SSH short form).  Everything else is a bare name.
  s.contains("://") or s.startsWith("git@")

# ---------------------------------------------------------------------------
# Single-require resolution
# ---------------------------------------------------------------------------

proc resolveRequire*(
    reqName:    string,
    constraint: string,
    idx:        PackagesIndex,
): Option[ResolvedRequire] =
  ## Resolve one `(reqName, constraint)` entry against the packages.json index.
  ##
  ## Returns `some(ResolvedRequire)` on success; `none` when the name is
  ## absent from the index or any URL derivation fails (the caller records
  ## the name as unresolved in both failure modes).
  if looksLikeUrl(reqName):
    # Case 2: URL require — self-qualify via deriveRepo
    let rr = deriveRepo(reqName)
    if rr.isErr or rr.get.repo.len == 0:
      return none(ResolvedRequire)
    let r = rr.get
    return some(ResolvedRequire(
      namespace:  r.host & "/" & r.org,
      name:       r.repo,
      constraint: constraint,
    ))
  else:
    # Case 1 or 3: bare name
    if reqName notin idx:
      return none(ResolvedRequire)   # Case 3 — absent
    let url = idx[reqName]
    let fr = deriveNamespace(url)
    if fr.isErr:
      return none(ResolvedRequire)   # looked-up URL underivable → unresolved
    return some(ResolvedRequire(
      namespace:  namespaceString(fr.get),
      name:       reqName,
      constraint: constraint,
    ))

# ---------------------------------------------------------------------------
# Batch resolution
# ---------------------------------------------------------------------------

proc resolveRequires*(
    requires: OrderedTable[string, string],
    idx:      PackagesIndex,
): RequireResolution =
  ## Resolve an entire requires map, partitioning into resolved / unresolved.
  ##
  ## Order of the resolved seq mirrors the iteration order of `requires`
  ## (which is already alphabetically canonical after `canonicalize`).
  ## Unresolved names are appended in their iteration order as well.
  result = RequireResolution()
  for name, constraint in requires.pairs:
    let r = resolveRequire(name, constraint, idx)
    if r.isSome:
      result.resolved.add(r.get)
    else:
      result.unresolved.add(name)
