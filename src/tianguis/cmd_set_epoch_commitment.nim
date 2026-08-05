## Subcommand: `tianguis set-epoch-commitment [--execute]` — arms the
## D-Watermark pre-epoch set commitment (milpa
## `docs/rfc-attestation-v1-normative.md` §6 slice **S-EpochCommitment**;
## spec `registry-protocol.md` §3.4.8/§3.4.9; tianguis-side cross-repo
## prerequisite).
##
## `Index.attestationEpochCommitment` (model.nim) is a NEW, distinct root
## field from `attestationEpoch` (the pre-existing timestamp ratchet) — an
## **append-once** field (spec §3.5.1): legal exactly once, `absent → C`.
## This command computes `C` itself, fresh, from the CURRENT index content —
## it never accepts an operator-supplied `C` — so what gets armed is
## provably the commitment digest of exactly the set `S` this run enumerated
## (no possibility of a stale or hand-typed pointer that doesn't match any
## real sidecar).
##
## `S` (the "grandfather-all" set, milpa RFC §6 F-op) is every
## `(namespace, name, version, content_hash)` identity present in the index
## AT ARMING TIME — every entry that exists when the commitment is minted
## becomes pre-epoch/grandfathered by definition; nothing published
## thereafter is a member.
##
## Architecture (mirrors cmd_migrate.nim's dry-run/--execute convention,
## crossed with cmd_set_attestation_epoch.nim's SET-ONCE-class guard):
##   Pure core:    (delegates to preepoch_commitment.enumerateCurrentSet /
##                  commitmentDigest — no re-derivation here)
##   Pure renderer: renderPreepochDryRun(identities, commitment) → string
##   Thin I/O:      cmdSetEpochCommitment(projectDir, execute) → int
##
## UX safety: dry-run (execute=false) is the default. Dry-run prints the
## full enumerated `S` plus the resulting `C` and writes nothing — this is
## deliverable (a) "dry-run/diff of S" from the tianguis-side build brief.
## Mutation requires explicit `--execute`, and even then refuses (SET-ONCE
## guard, deliverable (b)) if `attestation-epoch-commitment` is already
## present — the ratchet cannot be re-armed or re-typed once set (D16: doing
## so would trip milpa's `TNG-INDEX-ROOT-MUTATED` for every consumer with an
## established baseline).
##
## IMPORTANT — sequencing: arming this field on `index.kdl` alone is NOT
## sufficient for a consumer to see `Armed` rather than `ArmingInvalid`. The
## `.epoch-commitment` sidecar (enumerated `S` + a composed-verified Sigstore
## bundle over `C`, spec §3.4.9) must exist at
## `<index_base_url>/index.kdl.epoch-commitment` BEFORE (or atomically with)
## this command's `--execute` mutation lands on `main` — see
## `.github/workflows/attest-epoch-commitment.yaml`, which sequences:
## enumerate `S`/compute `C` → sign the commitment statement → commit+push
## the sidecar → THEN run this command's `--execute` → commit+push
## index.kdl → re-sign `index.kdl.bundle` (`attest-index.yaml`). This binary
## alone does not enforce that ordering; it is the workflow's job.
##
## Exit codes:
##   0 — success (dry-run printed the diff, or --execute armed)
##   1 — index.kdl missing or malformed
##   3 — SET-ONCE guard: attestation-epoch-commitment already set
##       (--execute only). Writes nothing.

import std/[os, options, strutils]
import ./model
import ./kdl_io
import ./fileutil
import ./preepoch_commitment

# ---------------------------------------------------------------------------
# Pure renderer
# ---------------------------------------------------------------------------

proc renderPreepochDryRun*(identities: seq[PreEpochIdentity], commitment: string): string =
  ## Render the full dry-run diff to a string: every identity that would
  ## become a member of `S`, plus the resulting commitment `C`. Caller is
  ## responsible for printing to stdout.
  let ordered = sortedDeduped(identities)
  var lines: seq[string] = @[]
  lines.add("tianguis set-epoch-commitment — dry run")
  lines.add("  pre-epoch set S: " & $ordered.len & " identit" &
    (if ordered.len == 1: "y" else: "ies"))
  for id in ordered:
    lines.add("    " & id.namespace & "/" & id.name & "@" & id.version &
      " (" & id.contentHash & ")")
  lines.add("  commitment C: " & commitment)
  lines.add("")
  lines.add("DRY RUN — no changes written; re-run with --execute to arm")
  lines.join("\n") & "\n"

# ---------------------------------------------------------------------------
# Thin I/O
# ---------------------------------------------------------------------------

proc cmdSetEpochCommitment*(projectDir: string, execute: bool): int =
  ## `tianguis set-epoch-commitment [--execute]`
  ##
  ## Default (execute=false): dry-run — enumerate S from the current
  ## index.kdl, compute C, print the diff to stdout, write nothing.
  ##
  ## With execute=true: SET-ONCE guard, then write
  ## `attestation-epoch-commitment "<C>"` to index.kdl. Does NOT regenerate
  ## index.json itself (mirrors cmd_set_attestation_epoch.nim) — the caller
  ## runs `tianguis project` afterward.
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
  let identities = enumerateCurrentSet(idx)
  let commitment = commitmentDigest(identities)

  if not execute:
    echo renderPreepochDryRun(identities, commitment)
    return 0

  if idx.attestationEpochCommitment.isSome:
    stderr.writeLine("tianguis: set-epoch-commitment: attestation-epoch-commitment already set to " &
      idx.attestationEpochCommitment.get &
      "; it is append-once and cannot be re-armed or re-typed")
    return 3

  var newIdx = idx
  newIdx.attestationEpochCommitment = some(commitment)
  atomicWrite(indexPath, formatKdl(newIdx))
  echo "tianguis: set-epoch-commitment: attestation-epoch-commitment set to " & commitment
  echo "run `tianguis project` to regenerate index.json"
  0
