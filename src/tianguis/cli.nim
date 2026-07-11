## tianguis CLI: thin orchestration over the kdl_io / json_io modules.
##
## `tianguis project` is the canonical command for keeping the JSON
## projection in sync with the KDL source-of-truth. CI invokes it with
## `--check` to fail builds on drift; humans run it without flags to
## regenerate index.json after editing index.kdl.

import std/[os, times]
import ./kdl_io
import ./json_io
import ./namespace
import ./attestation
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
