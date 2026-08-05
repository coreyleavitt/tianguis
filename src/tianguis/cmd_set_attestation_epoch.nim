## Subcommand: `tianguis set-attestation-epoch --epoch=<ISO8601>` — arms the
## S5 strict-attestation gate registry-wide (rfc-attestation-delivery
## handoff.md S5 deliverable 5 / tianguis#42).
##
## `Index.attestationEpoch` (model.nim) is a SET-ONCE (ratcheted) field: once
## armed, every version whose `published_at >= epoch` must carry a recognized
## attestation kind AND a bundle pin (`vendor/merge.nim`'s
## `attestationGateRejects`, the actual S5 predicate — reused here unchanged,
## see `findEpochViolations` below). This command is the one-shot admin
## operation that arms it, so it carries two hard guards:
##
##   1. SET-ONCE — refuses if `attestationEpoch` is already `some`. The
##      ratchet cannot be moved once armed (mirrors milpa's own read-side
##      ratchet discipline, #185 ATTESTATION_MONOTONE).
##   2. SAFETY — refuses if arming the proposed epoch would immediately make
##      any EXISTING entry violate the gate (a pinless/unattested entry whose
##      `published_at >= epoch`). Arming a gate the current index already
##      fails would make `entry-trust "strict"` reject on milpa's next fetch
##      for every such entry; backfill (`tianguis backfill`) must run first.
##
## Architecture (mirrors cmd_migrate.nim):
##   Pure core:  isValidEpochFormat, findEpochViolations
##   Thin I/O:   cmdSetAttestationEpoch(projectDir, epoch) → int

import std/[os, options]
import ./model
import ./kdl_io
import ./fileutil
import ./vendor/merge

# ---------------------------------------------------------------------------
# Pure core
# ---------------------------------------------------------------------------

type
  EpochViolation* = object
    ## One existing entry that would become post-epoch-but-unattested if the
    ## candidate epoch were armed.
    namespace*:   string
    packageName*: string
    version*:     string
    publishedAt*: string

proc isValidEpochFormat*(epoch: string): bool =
  ## True iff `epoch` is exactly the canonical UTC ISO-8601 shape tianguis
  ## emits for `published_at` — `YYYY-MM-DDTHH:MM:SSZ` (see `nowStr` in
  ## addentry.nim/cli.nim; `merge.nim`'s `attestationGateRejects` doc comment
  ## on why this exact fixed-width, zero-padded, always-'Z' shape is what
  ## makes byte-lexicographic order == chronological order). No timezone
  ## offsets, no fractional seconds, no surrounding whitespace.
  ##
  ## The strict digits-and-fixed-separators-only charset is also what closes
  ## the control-character requirement: nothing outside `[0-9]` plus the
  ## literal `-`/`T`/`:`/`Z` separators can ever pass this check, so a
  ## control byte anywhere in the input is rejected by construction — no
  ## separate blocklist needed (root-cause via a strict allowlist, matching
  ## the discipline milpa's TNG-UNSAFE-CONTROL-CHAR fix applied on its side).
  if epoch.len != 20: return false
  const SepIdx = [4, 7, 10, 13, 16, 19]
  const Seps = ['-', '-', 'T', ':', ':', 'Z']
  for i, idx in SepIdx:
    if epoch[idx] != Seps[i]: return false
  for i, c in epoch:
    if i in SepIdx: continue
    if c notin {'0'..'9'}: return false

  # Calendar-range sanity (well-formed, not just shape-matching).
  proc digits(a, b: int): int =
    var n = 0
    for i in a .. b: n = n * 10 + (ord(epoch[i]) - ord('0'))
    n
  let month = digits(5, 6)
  let day   = digits(8, 9)
  let hour  = digits(11, 12)
  let minute = digits(14, 15)
  let second = digits(17, 18)
  if month notin 1..12: return false
  if day notin 1..31: return false
  if hour notin 0..23: return false
  if minute notin 0..59: return false
  if second notin 0..59: return false
  true

proc findEpochViolations*(idx: Index, epoch: string): seq[EpochViolation] =
  ## Return every EXISTING (namespace, name, version) entry in `idx` that
  ## would become post-epoch-but-unattested if `epoch` were armed as
  ## `Index.attestationEpoch`. Does not mutate `idx`.
  ##
  ## Reuses `vendor/merge.mergeVendored` — NOT a re-derivation of the
  ## lexicographic publishedAt/epoch compare — to get the exact S5 verdict.
  ## `mergeVendored`'s documented priority ordering checks
  ## `attestationGateRejects` FIRST, before any identity/collision/signer/
  ## content-drift logic, and returns `mokMissingAttestation` immediately
  ## when it fires — so calling it with a synthetic entry built from each
  ## already-stored (package, version) pair, against a candidate index
  ## carrying the PROPOSED epoch, yields precisely the same verdict
  ## `attestationGateRejects` would without this proc (or any caller)
  ## re-deriving the comparison a second time. The candidate index is never
  ## persisted; `idx` itself is untouched.
  let candidateIdx = Index(
    schemaVersion:    idx.schemaVersion,
    attestationEpoch: some(epoch),
    attestationEpochCommitment: idx.attestationEpochCommitment,
    packages:         idx.packages,
  )
  for pkg in idx.packages:
    for v in pkg.versions:
      let entry = VendoredEntry(
        package: Package(name: pkg.name, namespace: pkg.namespace, upstream: pkg.upstream),
        version: v,
      )
      let (_, outcome) = mergeVendored(candidateIdx, entry)
      if outcome.kind == mokMissingAttestation:
        result.add(EpochViolation(
          namespace:   pkg.namespace,
          packageName: pkg.name,
          version:     v.version,
          publishedAt: v.publishedAt,
        ))

# ---------------------------------------------------------------------------
# Thin I/O
# ---------------------------------------------------------------------------

const MaxOffendersShown = 10

proc cmdSetAttestationEpoch*(projectDir: string, epoch: string): int =
  ## `tianguis set-attestation-epoch --epoch=<ISO8601>`
  ##
  ## Exit codes:
  ##   0 — success; index.kdl now carries `attestation-epoch` at the root
  ##   1 — index.kdl missing or malformed
  ##   2 — malformed --epoch (not the exact YYYY-MM-DDTHH:MM:SSZ shape, or
  ##       not a well-formed calendar timestamp). Writes nothing.
  ##   3 — SET-ONCE guard: attestation-epoch is already set. Writes nothing.
  ##   4 — SAFETY guard: arming this epoch would make one or more existing
  ##       entries violate the strict-attestation gate. Writes nothing.
  if not isValidEpochFormat(epoch):
    stderr.writeLine("tianguis: set-attestation-epoch: reject: --epoch must be " &
      "a well-formed ISO-8601 UTC timestamp of the exact shape " &
      "YYYY-MM-DDTHH:MM:SSZ (same shape as published_at), got: '" & epoch & "'")
    return 2

  let indexPath = projectDir / "index.kdl"
  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1

  let parsed = parseKdl(readFile(indexPath))
  if parsed.isErr:
    let e = parsed.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  let idx = parsed.get

  if idx.attestationEpoch.isSome:
    stderr.writeLine("tianguis: set-attestation-epoch: attestation-epoch already set to " &
      idx.attestationEpoch.get & "; it is set-once (ratcheted) and cannot be changed")
    return 3

  let violations = findEpochViolations(idx, epoch)
  if violations.len > 0:
    stderr.writeLine("tianguis: set-attestation-epoch: setting this epoch would make " &
      $violations.len &
      " existing entries violate the strict-attestation gate; backfill them first")
    for i, v in violations:
      if i >= MaxOffendersShown:
        stderr.writeLine("  ... and " & $(violations.len - MaxOffendersShown) & " more")
        break
      stderr.writeLine("  " & v.namespace & "/" & v.packageName & "@" & v.version &
        " (published_at=" & v.publishedAt & ")")
    return 4

  var newIdx = idx
  newIdx.attestationEpoch = some(epoch)
  atomicWrite(indexPath, formatKdl(newIdx))
  echo "tianguis: set-attestation-epoch: attestation-epoch set to " & epoch
  echo "run `tianguis project` to regenerate index.json"
  0
