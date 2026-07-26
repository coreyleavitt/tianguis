## CLI tests for `tianguis attest-index-statement` — the whole-index
## counterpart to `attest-statement`'s S7c seam (milpa `docs/rfc-registry-
## trust-federation.md` §4/§7.3, TNG-INDEX-BUNDLE-MISSING).
##
## Like `attest-statement`, this subcommand is pure (no driver, no
## filesystem I/O): it just validates args and prints the whole-index
## in-toto statement JSON to stdout, so `scripts/sign_statement.py` never
## re-derives the statement bytes in Python.

import std/[unittest, json, strutils]
import tianguis/[cli, attestation]

suite "cli attest-index-statement":
  test "emits exactly buildIndexStatement's JSON for the same inputs":
    let args = AttestIndexStatementArgs(
      contentHash: "a".repeat(64),
      signedBy: "https://github.com/coreyleavitt/tianguis/.github/workflows/attest-index.yaml@refs/heads/main",
    )
    let r = attestIndexStatementResult(args)
    check r.code == 0
    check r.stderr == ""
    let expected = buildIndexStatement(args.contentHash, args.signedBy)
    check r.stdout == expected
    # sanity: it really is the whole-index subject shape milpa's verifier expects
    let j = parseJson(r.stdout)
    check j["subject"][0]["name"].getStr == "index.kdl"
    check j["subject"][0]["digest"]["sha256"].getStr == "a".repeat(64)

  test "missing --content-hash fails: exit 4, empty stdout, non-empty stderr":
    let args = AttestIndexStatementArgs(
      signedBy: "https://vendor-bot.example/identity",
    )
    let r = attestIndexStatementResult(args)
    check r.code == 4
    check r.stdout == ""
    check r.stderr.len > 0

  test "missing --signed-by fails: exit 4":
    let args = AttestIndexStatementArgs(contentHash: "b".repeat(64))
    check attestIndexStatementResult(args).code == 4

  test "all args empty: exit 4, no crash":
    check attestIndexStatementResult(AttestIndexStatementArgs()).code == 4

  test "cmdAttestIndexStatement (I/O wrapper) mirrors the pure core's exit code":
    let goodArgs = AttestIndexStatementArgs(
      contentHash: "c".repeat(64),
      signedBy: "https://vendor-bot.example/identity",
    )
    check cmdAttestIndexStatement(goodArgs) == 0
    check cmdAttestIndexStatement(AttestIndexStatementArgs()) == 4

  test "determinism: same inputs via the CLI core produce byte-identical output":
    let args = AttestIndexStatementArgs(
      contentHash: "d".repeat(64),
      signedBy: "https://vendor-bot.example/identity",
    )
    let a = attestIndexStatementResult(args)
    let b = attestIndexStatementResult(args)
    check a.stdout == b.stdout
