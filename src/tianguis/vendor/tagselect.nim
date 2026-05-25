## Tag-selection heuristic for vendor-en-absentia entries.
##
## Given the tags advertised by an upstream's git remote plus its HEAD
## sha, pick which version the vendoring bot should record:
##
##   1. Semver-shaped tag (X.Y.Z or vX.Y.Z, with numeric parts) — pick
##      the highest by parsed triple.
##   2. Otherwise: any tag exists → pick the lex-last (deterministic
##      across runs; arbitrary but reproducible).
##   3. Otherwise: no tags → fall back to HEAD with synthetic version
##      "0.0.0+commit-<7chars-of-sha>".

import std/[algorithm, strutils]

type
  TagSelectionKind* = enum
    tskSemver, tskAnyTag, tskHead

  TagSelection* = object
    kind*:    TagSelectionKind
    tag*:     string    ## tag name as listed by upstream; empty for tskHead
    version*: string    ## version string we record in the index entry

proc isSemverShaped(tag: string): bool =
  let core = if tag.len > 0 and tag[0] == 'v': tag[1..^1] else: tag
  let parts = core.split('.')
  if parts.len != 3: return false
  for p in parts:
    if p.len == 0: return false
    for c in p:
      if c notin '0'..'9': return false
  true

proc semverTriple(tag: string): (int, int, int) =
  let core = if tag.len > 0 and tag[0] == 'v': tag[1..^1] else: tag
  let parts = core.split('.')
  (parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]))

proc selectTag*(tags: seq[string], headSha: string): TagSelection =
  ## See module docstring for the heuristic.
  var semverTags: seq[string] = @[]
  for t in tags:
    if isSemverShaped(t): semverTags.add(t)

  if semverTags.len > 0:
    # Pick the highest by parsed triple.
    var best = semverTags[0]
    for t in semverTags[1..^1]:
      if semverTriple(t) > semverTriple(best):
        best = t
    let core = if best.len > 0 and best[0] == 'v': best[1..^1] else: best
    return TagSelection(kind: tskSemver, tag: best, version: core)

  if tags.len > 0:
    var sorted = tags
    sorted.sort()
    let last = sorted[^1]
    return TagSelection(kind: tskAnyTag, tag: last, version: last)

  let shortSha = if headSha.len >= 7: headSha[0..6] else: headSha
  TagSelection(kind: tskHead, tag: "", version: "0.0.0+commit-" & shortSha)
