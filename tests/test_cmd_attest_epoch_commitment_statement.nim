## CLI tests for `tianguis attest-epoch-commitment-statement` — the
## D-Watermark pre-epoch set commitment counterpart to
## `attest-index-statement`'s S7c seam (milpa
## `docs/rfc-attestation-v1-normative.md` §6 S-EpochCommitment).
##
## Like `attest-index-statement`, this subcommand is pure (no driver, no
## filesystem I/O): it validates args and prints the epoch-commitment
## in-toto statement JSON to stdout, so `scripts/sign_statement.py` never
## re-derives the statement bytes in Python.

import std/[unittest, json, strutils]
import tianguis/[cli, attestation]

suite "cli attest-epoch-commitment-statement":
  test "emits exactly buildEpochCommitmentStatement's JSON for the same inputs":
    let args = AttestEpochCommitmentStatementArgs(
      commitment: "a".repeat(64),
      signedBy: "https://github.com/coreyleavitt/tianguis/.github/workflows/attest-epoch-commitment.yaml@refs/heads/main",
    )
    let r = attestEpochCommitmentStatementResult(args)
    check r.code == 0
    check r.stderr == ""
    let expected = buildEpochCommitmentStatement(args.commitment, args.signedBy)
    check r.stdout == expected
    # sanity: it really is the epoch-commitment subject shape milpa's
    # verifier expects — digest.sha256 == C, subject name is the fixed marker.
    let j = parseJson(r.stdout)
    check j["subject"][0]["name"].getStr == "milpa-preepoch-set-commitment"
    check j["subject"][0]["digest"]["sha256"].getStr == "a".repeat(64)

  test "missing --commitment fails: exit 4, empty stdout, non-empty stderr":
    let args = AttestEpochCommitmentStatementArgs(
      signedBy: "https://vendor-bot.example/identity",
    )
    let r = attestEpochCommitmentStatementResult(args)
    check r.code == 4
    check r.stdout == ""
    check r.stderr.len > 0

  test "missing --signed-by fails: exit 4":
    let args = AttestEpochCommitmentStatementArgs(commitment: "b".repeat(64))
    check attestEpochCommitmentStatementResult(args).code == 4

  test "all args empty: exit 4, no crash":
    check attestEpochCommitmentStatementResult(AttestEpochCommitmentStatementArgs()).code == 4

  test "--commitment not exactly 64 hex chars fails: exit 4":
    let args = AttestEpochCommitmentStatementArgs(
      commitment: "too-short",
      signedBy: "https://vendor-bot.example/identity",
    )
    check attestEpochCommitmentStatementResult(args).code == 4

  test "cmdAttestEpochCommitmentStatement (I/O wrapper) mirrors the pure core's exit code":
    let goodArgs = AttestEpochCommitmentStatementArgs(
      commitment: "c".repeat(64),
      signedBy: "https://vendor-bot.example/identity",
    )
    check cmdAttestEpochCommitmentStatement(goodArgs) == 0
    check cmdAttestEpochCommitmentStatement(AttestEpochCommitmentStatementArgs()) == 4

  test "determinism: same inputs via the CLI core produce byte-identical output":
    let args = AttestEpochCommitmentStatementArgs(
      commitment: "d".repeat(64),
      signedBy: "https://vendor-bot.example/identity",
    )
    let a = attestEpochCommitmentStatementResult(args)
    let b = attestEpochCommitmentStatementResult(args)
    check a.stdout == b.stdout
