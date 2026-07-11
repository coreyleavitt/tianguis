## Persisted candidate/pin records for the two-phase attestation-bundle
## minting flow (rfc-attestation-delivery.handoff.md S7b; tianguis#42).
##
## Sigstore signing needs GitHub Actions OIDC and cannot run inside the Nim
## binary (see the handoff's "HARD CONSTRAINT" note — milpa's verifier
## hardcodes the GH-Actions issuer), so `tianguis vendor` cannot mint bundles
## inline for post-epoch entries. Instead it runs in two Nim-side passes,
## both driven by this module's records, with a CI-only mint step between
## them:
##
##   1. `tianguis vendor --emit-bundle-candidates=<path>` — the normal vendor
##      pass merges everything it can; every entry rejected ONLY because it
##      is post-epoch and lacks a bundle pin (mokMissingAttestation, and not
##      already pinned elsewhere in the index — see orchestrate.nim's
##      `alreadyPinnedInIndex`) is ALSO captured here as a `BundleCandidate`
##      and written to `<path>` as JSON. Candidates carry every field needed
##      both to mint the bundle (namespace/name/version/content_hash) AND to
##      reconstruct the merge-able entry (upstream/commit_sha/git_ref/
##      published_at) — so neither the workflow's mint loop NOR this
##      module's apply step ever re-fetches upstream.
##   2. The workflow's mint loop (scripts/mint_bundle.py) reads the
##      candidates file, mints one bundle per candidate (cosign/sigstore
##      under ambient OIDC — CI-only), and writes a pins file: each
##      candidate record augmented with the minted `bundle_pin`.
##   3. `tianguis vendor --bundle-pins=<path>` reads that pins file and the
##      current index.kdl, reconstructs each entry from its persisted
##      candidate fields (`buildVendoredEntryFromCandidate`, merge.nim — NO
##      Driver, NO network), and merges it in. The S5 epoch gate now passes
##      because the pin is present.
##
## The JSON key names below (`content_hash`, `commit_sha`, `git_ref`,
## `published_at`, `bundle_pin`) match the snake_case convention already
## used by `json_io.nim`'s index projection — same field, same spelling.

import std/json
import nkdl  # Result[T,E], ok(), err() — re-exported from nkdl/spans
import ../kdl_io  # isHex64 — single source of truth for the pin format

export nkdl

type
  BundleCandidate* = object
    ## Everything needed to (a) mint a bundle for this entry and (b)
    ## reconstruct the VendoredEntry for merge, without a second fetch.
    namespace*:   string
    name*:        string
    version*:     string
    contentHash*: string
    upstream*:    string
    commitSha*:   string
    gitRef*:      string
    publishedAt*: string

  BundlePin* = object
    candidate*: BundleCandidate
    pin*:       string   ## 64-hex sha256 of the minted bundle's bytes

proc candidateToJson(c: BundleCandidate): JsonNode =
  %*{
    "namespace":    c.namespace,
    "name":         c.name,
    "version":      c.version,
    "content_hash": c.contentHash,
    "upstream":     c.upstream,
    "commit_sha":   c.commitSha,
    "git_ref":      c.gitRef,
    "published_at": c.publishedAt,
  }

proc candidatesToJson*(candidates: seq[BundleCandidate]): string =
  ## Serialize candidates for `--emit-bundle-candidates`. `std/json`'s
  ## `JObject` preserves insertion order, so repeated runs over identical
  ## input produce byte-identical output.
  var arr = newJArray()
  for c in candidates:
    arr.add(candidateToJson(c))
  pretty(arr)

proc candidateFromJson(node: JsonNode): BundleCandidate =
  BundleCandidate(
    namespace:   node{"namespace"}.getStr(""),
    name:        node{"name"}.getStr(""),
    version:     node{"version"}.getStr(""),
    contentHash: node{"content_hash"}.getStr(""),
    upstream:    node{"upstream"}.getStr(""),
    commitSha:   node{"commit_sha"}.getStr(""),
    gitRef:      node{"git_ref"}.getStr(""),
    publishedAt: node{"published_at"}.getStr(""),
  )

proc parseCandidatesJson*(text: string): Result[seq[BundleCandidate], string] =
  ## Parse a candidates file back into `BundleCandidate`s. Not needed by the
  ## Nim CLI itself (the mint loop, in Python, is the real consumer), but
  ## kept symmetric with `candidatesToJson` so the write side is round-trip
  ## tested rather than asserted only by string-matching JSON text.
  let node =
    try: parseJson(text)
    except JsonParsingError as e:
      return err[seq[BundleCandidate], string]("malformed JSON: " & e.msg)
  if node.kind != JArray:
    return err[seq[BundleCandidate], string](
      "candidates file root must be a JSON array")
  var candidates: seq[BundleCandidate] = @[]
  for item in node:
    candidates.add(candidateFromJson(item))
  ok[seq[BundleCandidate], string](candidates)

proc parsePinsJson*(text: string): Result[seq[BundlePin], string] =
  ## Parse the pins file the mint loop writes: a JSON array of candidate
  ## objects each augmented with `bundle_pin`. Every record must carry a
  ## non-empty, well-formed (64 lowercase hex) `bundle_pin` — a candidate
  ## the mint loop skipped (e.g. a minting failure) MUST NOT silently apply
  ## with a missing/malformed pin, and a malformed pin must never reach
  ## `formatKdl` (same discipline as `add-entry --bundle-pin`, kdl_io.isHex64
  ## is the single source of truth for the format).
  let node =
    try: parseJson(text)
    except JsonParsingError as e:
      return err[seq[BundlePin], string]("malformed JSON: " & e.msg)
  if node.kind != JArray:
    return err[seq[BundlePin], string]("pins file root must be a JSON array")
  var pins: seq[BundlePin] = @[]
  for item in node:
    let pin = item{"bundle_pin"}.getStr("")
    if not isHex64(pin):
      return err[seq[BundlePin], string](
        "pins entry has missing/invalid bundle_pin (must be 64 lowercase " &
        "hex characters): " & $item)
    pins.add(BundlePin(candidate: candidateFromJson(item), pin: pin))
  ok[seq[BundlePin], string](pins)
