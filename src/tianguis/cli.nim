## tianguis CLI: thin orchestration over the kdl_io / json_io modules.
##
## `tianguis project` is the canonical command for keeping the JSON
## projection in sync with the KDL source-of-truth. CI invokes it with
## `--check` to fail builds on drift; humans run it without flags to
## regenerate index.json after editing index.kdl.

import std/[os, times]
# `except parseJson`: json_io.nim (below) defines its OWN
# `parseJson*(s: string): Result[Index, IdxError]`; importing std/json's
# `parseJson` unqualified here too would make every call site ambiguous.
# Nothing in this file parses raw JSON (only builds it, in
# `showPreepochSetResult`), so excluding it is a clean, permanent fix.
import std/json except parseJson
import ./kdl_io
import ./json_io
import ./namespace
import ./attestation
import ./preepoch_commitment
import ./vendor/[denylist, orchestrate, driver, candidates, merge]

type
  AttestStatementArgs* = object
    ## Args for `tianguis attest-statement` (rfc-attestation-delivery
    ## handoff.md S7c). All six fields are required — see
    ## `attestStatementResult` for the exact rejection rule.
    namespace*:       string
    name*:            string
    version*:         string
    contentHash*:     string
    attestationKind*: string
    signedBy*:        string

proc attestStatementResult*(args: AttestStatementArgs): tuple[code: int, stdout, stderr: string] =
  ## Pure core for `tianguis attest-statement`.
  ## Returns (exit code, stdout text, stderr text) without any I/O side
  ## effects. `cmdAttestStatement` wraps this with actual echo/writeLine.
  ##
  ## This is the SINGLE source-of-truth CLI entry point for the S3 in-toto
  ## statement bytes: it does nothing but validate args and delegate to
  ## `buildEntryStatement` (attestation.nim), so scripts/sign_statement.py
  ## (the CI-only signing seam, S7c) never re-derives the statement in
  ## Python — it shells out here for the exact bytes to sign.
  if args.namespace.len == 0 or args.name.len == 0 or args.version.len == 0 or
      args.contentHash.len == 0 or args.attestationKind.len == 0 or
      args.signedBy.len == 0:
    return (code: 4, stdout: "", stderr:
      "missing required argument(s); need --namespace --name --version " &
      "--content-hash --attestation-kind --signed-by")
  let stmt = buildEntryStatement(
    args.namespace, args.name, args.version, args.contentHash,
    args.attestationKind, args.signedBy,
  )
  (code: 0, stdout: stmt, stderr: "")

proc cmdAttestStatement*(args: AttestStatementArgs): int =
  ## `tianguis attest-statement`: print the S3 in-toto statement JSON for one
  ## entry to stdout, or a clear error to stderr with a non-zero exit code.
  let r = attestStatementResult(args)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis: attest-statement: " & r.stderr)
  r.code

type
  AttestIndexStatementArgs* = object
    ## Args for `tianguis attest-index-statement` — the whole-index
    ## counterpart to `attest-statement` (milpa `docs/rfc-registry-trust-
    ## federation.md` §4/§7.3 tianguis-side bundle-delivery gap,
    ## TNG-INDEX-BUNDLE-MISSING). Only two fields: unlike `attest-statement`,
    ## this command does no filesystem I/O — the caller (the `attest-index`
    ## reusable workflow) has already computed sha256(index.kdl) itself, so
    ## this stays pure like its per-entry sibling.
    contentHash*: string  ## sha256 hex of the raw `index.kdl` bytes (no scheme prefix)
    signedBy*:    string

proc attestIndexStatementResult*(
    args: AttestIndexStatementArgs
): tuple[code: int, stdout, stderr: string] =
  ## Pure core for `tianguis attest-index-statement`.
  ## Returns (exit code, stdout text, stderr text) without any I/O side
  ## effects. `cmdAttestIndexStatement` wraps this with actual echo/writeLine.
  ##
  ## The single source-of-truth CLI entry point for the whole-index in-toto
  ## statement bytes: it does nothing but validate args and delegate to
  ## `buildIndexStatement` (attestation.nim), so `scripts/sign_statement.py`
  ## (the same CI-only signing seam the per-entry path uses) never re-derives
  ## the statement in Python — it shells out here for the exact bytes to sign.
  if args.contentHash.len == 0 or args.signedBy.len == 0:
    return (code: 4, stdout: "", stderr:
      "missing required argument(s); need --content-hash --signed-by")
  let stmt = buildIndexStatement(args.contentHash, args.signedBy)
  (code: 0, stdout: stmt, stderr: "")

proc cmdAttestIndexStatement*(args: AttestIndexStatementArgs): int =
  ## `tianguis attest-index-statement`: print the whole-index in-toto
  ## Statement JSON to stdout, or a clear error to stderr with a non-zero
  ## exit code.
  let r = attestIndexStatementResult(args)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis: attest-index-statement: " & r.stderr)
  r.code

type
  AttestEpochCommitmentStatementArgs* = object
    ## Args for `tianguis attest-epoch-commitment-statement` — the
    ## D-Watermark pre-epoch set commitment counterpart to
    ## `attest-index-statement` (milpa `docs/rfc-attestation-v1-normative.md`
    ## §6 S-EpochCommitment). Like `attest-index-statement`, this command
    ## does no filesystem I/O — the caller (the minting workflow) has
    ## already enumerated `S` and computed `C` itself (via `tianguis
    ## show-preepoch-set`), so this stays pure like its sibling.
    commitment*: string  ## `C`: 64-char lowercase-hex sha256 digest
    signedBy*:   string

proc attestEpochCommitmentStatementResult*(
    args: AttestEpochCommitmentStatementArgs
): tuple[code: int, stdout, stderr: string] =
  ## Pure core for `tianguis attest-epoch-commitment-statement`.
  ## Returns (exit code, stdout text, stderr text) without any I/O side
  ## effects. `cmdAttestEpochCommitmentStatement` wraps this with actual
  ## echo/writeLine.
  ##
  ## The single source-of-truth CLI entry point for the epoch-commitment
  ## in-toto statement bytes: delegates to `buildEpochCommitmentStatement`
  ## (attestation.nim), so `scripts/sign_statement.py` (the same CI-only
  ## signing seam the per-entry and whole-index paths use) never re-derives
  ## the statement in Python.
  if args.commitment.len == 0 or args.signedBy.len == 0:
    return (code: 4, stdout: "", stderr:
      "missing required argument(s); need --commitment --signed-by")
  if args.commitment.len != 64:
    return (code: 4, stdout: "", stderr:
      "--commitment must be a 64-char lowercase-hex sha256 digest, got: '" &
        args.commitment & "'")
  let stmt = buildEpochCommitmentStatement(args.commitment, args.signedBy)
  (code: 0, stdout: stmt, stderr: "")

proc cmdAttestEpochCommitmentStatement*(args: AttestEpochCommitmentStatementArgs): int =
  ## `tianguis attest-epoch-commitment-statement`: print the epoch-commitment
  ## in-toto Statement JSON to stdout, or a clear error to stderr with a
  ## non-zero exit code.
  let r = attestEpochCommitmentStatementResult(args)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis: attest-epoch-commitment-statement: " & r.stderr)
  r.code

proc deriveNamespaceResult*(signedBy: string): tuple[code: int, stdout, stderr: string] =
  ## Pure core for `tianguis derive-namespace --signed-by=<url-or-SAN>`.
  ## Returns (exit code, stdout text, stderr text) without any I/O side
  ## effects. `cmdDeriveNamespace` wraps this with actual echo/writeLine.
  ##
  ## This is the SINGLE source-of-truth CLI entry point for namespace
  ## derivation (rfc-attestation-delivery handoff.md S8 Layer 2a,
  ## tianguis#42): both the author-side composite action (building the purl
  ## for `attest-statement --namespace=…`) and any other client-side caller
  ## MUST derive the exact same namespace `add-entry` will independently
  ## derive server-side from the same `--signed-by` value — that's what
  ## `deriveNamespace` (namespace.nim) already computes for add-entry; this
  ## subcommand just exposes it over the CLI so nothing re-derives or
  ## re-parses the SAN a second, possibly-divergent way.
  if signedBy.len == 0:
    return (code: 4, stdout: "", stderr:
      "missing required argument --signed-by")
  let derived = deriveNamespace(signedBy)
  if derived.isErr:
    return (code: 2, stdout: "", stderr: $derived.error)
  (code: 0, stdout: namespaceString(derived.get), stderr: "")

proc cmdDeriveNamespace*(signedBy: string): int =
  ## `tianguis derive-namespace --signed-by=<url-or-SAN>`: print the derived
  ## namespace (host/org) for a raw upstream URL or OIDC SAN to stdout, or a
  ## clear error to stderr with a non-zero exit code.
  let r = deriveNamespaceResult(signedBy)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis: derive-namespace: " & r.stderr)
  r.code

proc showResult*(url: string): tuple[code: int, stdout, stderr: string] =
  ## Pure core for `tianguis show <url>`.
  ## Returns (exit code, stdout text, stderr text) without any I/O side effects.
  ## `cmdShow` wraps this with actual echo/writeLine.
  let r = deriveRepo(url)
  if r.isErr:
    result = (code: 2, stdout: "", stderr: $r.error)
  else:
    let rr = r.get
    var outStr = "namespace=" & rr.host & "/" & rr.org
    if rr.repo.len > 0:
      outStr.add "\nrepo=" & rr.repo
    result = (code: 0, stdout: outStr, stderr: "")

proc cmdShow*(url: string): int =
  ## `tianguis show <url>`: print derived namespace (and repo hint) to stdout,
  ## or the DerivationError code to stderr with a non-zero exit code.
  let r = showResult(url)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis show: " & r.stderr)
  r.code

proc showPreepochSetResult*(projectDir: string): tuple[code: int, stdout, stderr: string] =
  ## Thin I/O core for `tianguis show-preepoch-set`: read index.kdl,
  ## enumerate the current pre-epoch set `S` (grandfather-all — every
  ## `(namespace, name, version, content_hash)` identity present in the
  ## index at call time, milpa RFC §6 S-EpochCommitment's F-op), and print
  ## it plus the resulting commitment `C` as JSON to stdout.
  ##
  ## Dual-purpose (single source of truth — no duplicate enumeration logic):
  ##   1. Human dry-run/diff — `cmd_set_epoch_commitment.cmdSetEpochCommitment`'s
  ##      default (non-`--execute`) mode renders this SAME result.
  ##   2. Machine payload for the minting workflow (`attest-epoch-commitment.
  ##      yaml`) — the printed `identities` array is combined with the
  ##      signed Sigstore bundle (`attest-epoch-commitment-statement` piped
  ##      into `scripts/sign_statement.py`) to build the final
  ##      `.epoch-commitment` sidecar (spec §3.4.9).
  ##
  ## Output shape: `{"identities": [...], "commitment": "<C>"}` — the
  ## `identities` array is already canonically sorted+deduped
  ## (`preepoch_commitment.identitiesToJson`), so `commitment` is always
  ## `commitmentDigest` of exactly the printed `identities` array — a
  ## consumer never needs to re-sort before recomputing `C` to check it.
  let kdlPath = projectDir / "index.kdl"
  if not fileExists(kdlPath):
    return (code: 1, stdout: "", stderr: kdlPath & " not found")
  let parsed = parseKdl(readFile(kdlPath))
  if parsed.isErr:
    let e = parsed.getErr
    return (code: 1, stdout: "", stderr: kdlPath & ": " & $e.code & ": " & e.message)
  let idx = parsed.get
  let s = enumerateCurrentSet(idx)
  let c = commitmentDigest(s)
  let node = %*{
    "identities": identitiesToJson(s),
    "commitment": c,
  }
  (code: 0, stdout: $node, stderr: "")

proc cmdShowPreepochSet*(projectDir: string): int =
  ## `tianguis show-preepoch-set`: print the current pre-epoch set `S` and
  ## its commitment `C` as JSON to stdout, or a clear error to stderr with a
  ## non-zero exit code. Read-only — never mutates index.kdl.
  let r = showPreepochSetResult(projectDir)
  if r.code == 0:
    echo r.stdout
  else:
    stderr.writeLine("tianguis: show-preepoch-set: " & r.stderr)
  r.code

proc cmdProject*(projectDir: string, check: bool): int =
  ## Read <projectDir>/index.kdl. If `check`, compare the parsed Index
  ## to the parsed <projectDir>/index.json and exit non-zero on any
  ## semantic difference. Otherwise regenerate index.json from the KDL
  ## source.
  ##
  ## Exit codes:
  ##   0 — success (parity confirmed, or regeneration completed)
  ##   1 — index.kdl missing or malformed
  ##   2 — drift detected (check mode) or parse error on index.json
  let kdlPath = projectDir / "index.kdl"
  let jsonPath = projectDir / "index.json"

  if not fileExists(kdlPath):
    stderr.writeLine("tianguis: " & kdlPath & " not found")
    return 1

  let kdlText = readFile(kdlPath)
  let kdlResult = parseKdl(kdlText)
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & kdlPath & ": " & $e.code & ": " & e.message)
    return 1

  if check:
    if not fileExists(jsonPath):
      stderr.writeLine("tianguis: " & jsonPath & " missing (run `tianguis project` to regenerate)")
      return 2
    let jsonText = readFile(jsonPath)
    let jsonResult = parseJson(jsonText)
    if jsonResult.isErr:
      let e = jsonResult.getErr
      stderr.writeLine("tianguis: " & jsonPath & ": " & $e.code & ": " & e.message)
      return 2
    if kdlResult.get != jsonResult.get:
      stderr.writeLine(
        "tianguis: index.kdl and index.json disagree (run `tianguis project` to regenerate)"
      )
      return 2
    return 0
  else:
    writeFile(jsonPath, formatJson(kdlResult.get))
    return 0

proc cmdVendor*(
    projectDir: string,
    emitCandidatesPath: string = "",
    bundlePinsPath:     string = "",
): int =
  ## Run one vendoring pass: fetch nim-lang/packages.json, merge new
  ## entries into index.kdl, append drift alerts to alerts.kdl.
  ##
  ## rfc-attestation-delivery S7b (tianguis#42): sigstore signing needs
  ## GitHub Actions OIDC and cannot happen inline in this binary, so
  ## post-epoch entries that lack a bundle pin are minted out-of-process
  ## (the vendor.yaml workflow) via two extra, mutually exclusive modes:
  ##
  ##   --bundle-pins=<path>        apply-only pass. NO network, NO Driver —
  ##                                reads <path> (a pins file the workflow's
  ##                                mint loop wrote) and index.kdl, merges
  ##                                each now-pinned entry in, writes
  ##                                index.kdl back. Takes precedence over
  ##                                --emit-bundle-candidates if both given.
  ##   --emit-bundle-candidates=<path>
  ##                                on a normal (network) vendor pass,
  ##                                additionally write the set of post-epoch
  ##                                entries that still need a bundle minted
  ##                                to <path> as JSON (consumed by the
  ##                                workflow's mint loop).
  ##
  ## Exit codes:
  ##   0 — pass completed (entries may or may not have been added; check
  ##       git diff)
  ##   1 — fatal I/O failure (network, malformed manifest, missing/malformed
  ##       --bundle-pins file, etc.)
  let indexPath    = projectDir / "index.kdl"
  let denylistPath = projectDir / "denylist.kdl"
  let alertsPath   = projectDir / "alerts.kdl"

  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1

  let kdlResult = parseKdl(readFile(indexPath))
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  if bundlePinsPath.len > 0:
    if not fileExists(bundlePinsPath):
      stderr.writeLine("tianguis: " & bundlePinsPath & " not found")
      return 1
    let pinsResult = parsePinsJson(readFile(bundlePinsPath))
    if pinsResult.isErr:
      stderr.writeLine("tianguis: vendor --bundle-pins: " & pinsResult.error)
      return 1
    let (newIdx, outcomes) = applyBundlePins(kdlResult.get, pinsResult.get)
    writeFile(indexPath, formatKdl(newIdx))
    for outcome in outcomes:
      case outcome.kind
      of mokMissingAttestation:
        # Should not happen — a parsed pin is always non-empty/valid — but
        # surface it rather than silently drop the entry if it ever does.
        let ma = outcome.missingAttestation
        stderr.writeLine("tianguis: vendor --bundle-pins: still missing attestation: " &
          ma.namespace & "/" & ma.packageName & "@" & ma.version)
      of mokIdentityDrift, mokCollision, mokContentDrift, mokSignerMismatch:
        # mokSignerMismatch is unreachable here in practice — applyBundlePins
        # only ever reconstructs milpa-vendored entries (buildVendoredEntry-
        # FromCandidate), which the S8 Layer 3 ratchet never gates — but kept
        # in this exhaustive bucket rather than silently dropped.
        stderr.writeLine("tianguis: vendor --bundle-pins: rejected (" & $outcome.kind & ")")
      of mokAdded, mokIdempotent, mokRebaselined:
        discard
    return 0

  let dl = if fileExists(denylistPath):
             parseDenylist(readFile(denylistPath))
           else: Denylist()
  let existingAlerts = if fileExists(alertsPath):
                         readFile(alertsPath)
                       else: ""

  let driver = newRealDriver()
  let res = try:
    runVendor(
      driver,
      initialIndex  = kdlResult.get,
      denylist      = dl,
      initialAlerts = existingAlerts,
      nowIso        = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    )
  except IOError as e:
    stderr.writeLine("tianguis: vendor I/O error: " & e.msg)
    return 1

  writeFile(indexPath, formatKdl(res.index))
  if res.alerts != existingAlerts:
    writeFile(alertsPath, res.alerts)
  for skipped in res.skipped:
    stderr.writeLine("tianguis: skipped denylisted package " & skipped)
  if emitCandidatesPath.len > 0:
    writeFile(emitCandidatesPath, candidatesToJson(res.candidates))
  return 0

proc cmdBackfill*(
    projectDir:         string,
    emitCandidatesPath: string = "",
    bundlePinsPath:     string = "",
    cap:                int    = 0,
): int =
  ## `tianguis backfill` (rfc-attestation-delivery.handoff.md S9; tianguis#42):
  ## batched minting of vendored bundles for entries ALREADY in index.kdl.
  ## Two mutually exclusive modes (same precedence rule as `tianguis vendor`:
  ## `--bundle-pins` wins if both are given):
  ##
  ##   --bundle-pins=<path>              apply-only pass. NO network. Reads
  ##                                     <path> (a pins file a mint loop
  ##                                     wrote) and index.kdl, sets
  ##                                     `bundlePin` on each matching EXISTING
  ##                                     entry via `applyBackfillPins`, writes
  ##                                     index.kdl back.
  ##   --emit-bundle-candidates=<path>   full-index sweep: write every
  ##                                     existing entry that lacks a bundle
  ##                                     pin and is eligible
  ##                                     (`enumerateBackfillCandidates`,
  ##                                     orchestrate.nim) to <path> as JSON.
  ##
  ## Deliberately DOES NOT reuse `tianguis vendor --bundle-pins` for the
  ## apply side, even though the candidate JSON shape is identical to S7b's:
  ## `mergeVendored` (what `vendor --bundle-pins` drives) treats a matching
  ## (version, content_hash) as fully idempotent and silently discards the
  ## incoming bundlePin — correct for S7b (whose candidates were NEVER
  ## admitted, so `mergeVendored` always inserts a genuinely new version) but
  ## silently wrong for backfill (whose candidates are, by construction,
  ## entries ALREADY sitting in the index — that's what makes them
  ## "backfill" rather than "new"). `applyBackfillPins` does the narrower,
  ## correct operation instead: find the exact existing entry, confirm its
  ## content_hash still matches, and set the pin in place.
  ##
  ## `cap` (0 or negative = unlimited) optionally bounds how many candidates
  ## a single `--emit-bundle-candidates` pass emits — a full backfill sweep
  ## can be large, and bounding it keeps one CI mint-loop's runtime
  ## predictable. Capping never silently truncates: the number of
  ## eligible-but-skipped candidates is logged to stderr so a re-run is
  ## visibly still needed.
  ##
  ## Exit codes:
  ##   0 — pass completed (candidates/pins written; entries may or may not
  ##       have changed — check git diff)
  ##   1 — fatal I/O failure (index.kdl missing/malformed, missing/malformed
  ##       --bundle-pins file, or neither flag given)
  let indexPath = projectDir / "index.kdl"

  if bundlePinsPath.len > 0:
    if not fileExists(bundlePinsPath):
      stderr.writeLine("tianguis: " & bundlePinsPath & " not found")
      return 1
    let pinsResult = parsePinsJson(readFile(bundlePinsPath))
    if pinsResult.isErr:
      stderr.writeLine("tianguis: backfill --bundle-pins: " & pinsResult.error)
      return 1
    if not fileExists(indexPath):
      stderr.writeLine("tianguis: " & indexPath & " not found")
      return 1
    let kdlResult = parseKdl(readFile(indexPath))
    if kdlResult.isErr:
      let e = kdlResult.getErr
      stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
      return 1
    let (newIdx, outcomes) = applyBackfillPins(kdlResult.get, pinsResult.get)
    writeFile(indexPath, formatKdl(newIdx))
    for outcome in outcomes:
      case outcome.kind
      of bokPinned, bokAlreadyPinned: discard
      of bokNotFound:
        stderr.writeLine("tianguis: backfill --bundle-pins: no matching entry for " &
          outcome.namespace & "/" & outcome.packageName & "@" & outcome.version)
      of bokContentMismatch:
        stderr.writeLine("tianguis: backfill --bundle-pins: content_hash mismatch, " &
          "refusing to pin " & outcome.namespace & "/" & outcome.packageName &
          "@" & outcome.version)
    return 0

  if emitCandidatesPath.len == 0:
    stderr.writeLine("tianguis: backfill: one of --emit-bundle-candidates=<path> " &
      "or --bundle-pins=<path> is required")
    return 1

  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1

  let kdlResult = parseKdl(readFile(indexPath))
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  let all = enumerateBackfillCandidates(kdlResult.get)
  let (kept, skipped) = applyCandidateCap(all, cap)
  if skipped > 0:
    stderr.writeLine("tianguis: backfill: capped at " & $kept.len &
      " candidate(s); " & $skipped &
      " eligible candidate(s) skipped this pass — re-run to continue backfilling them")
  writeFile(emitCandidatesPath, candidatesToJson(kept))
  return 0

proc cmdReindex*(projectDir: string): int =
  ## Epoch-migration pass: re-vendor every package and re-baseline each
  ## content_hash to the epoch-2 dag-sha256 value produced by `milpa hash`.
  ## Unlike the normal vendor pass, content-hash changes for known
  ## (namespace, name, version) triples are ACCEPTED (mokRebaselined) rather
  ## than rejected as drift. Identity-drift and collision protections still
  ## apply. Writes both index.kdl and index.json.
  ##
  ## Exit codes:
  ##   0 — pass completed (index files updated)
  ##   1 — fatal I/O failure (network, malformed manifest, etc.)
  let indexPath    = projectDir / "index.kdl"
  let jsonPath     = projectDir / "index.json"
  let denylistPath = projectDir / "denylist.kdl"
  let alertsPath   = projectDir / "alerts.kdl"

  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1

  let kdlResult = parseKdl(readFile(indexPath))
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  let dl = if fileExists(denylistPath):
             parseDenylist(readFile(denylistPath))
           else: Denylist()
  let existingAlerts = if fileExists(alertsPath):
                         readFile(alertsPath)
                       else: ""

  let driver = newRealDriver()
  let res = try:
    runVendor(
      driver,
      initialIndex  = kdlResult.get,
      denylist      = dl,
      initialAlerts = existingAlerts,
      nowIso        = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
      rebaseline    = true,
    )
  except IOError as e:
    stderr.writeLine("tianguis: reindex I/O error: " & e.msg)
    return 1

  writeFile(indexPath, formatKdl(res.index))
  writeFile(jsonPath, formatJson(res.index))
  if res.alerts != existingAlerts:
    writeFile(alertsPath, res.alerts)
  return 0
