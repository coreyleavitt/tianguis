## CLI tests for `tianguis attest-statement` — the S7c single-source seam.
##
## This subcommand exposes the S3 `buildEntryStatement` builder over the CLI
## so scripts/sign_statement.py (the CI-only signing seam) never re-derives
## the in-toto statement bytes in Python — there must be exactly ONE place
## that computes the subject/predicate JSON (rfc-attestation-delivery
## handoff.md S7c). Unlike `add-entry`, this command is pure (no driver, no
## filesystem I/O): it just validates args and prints JSON to stdout.

import std/[unittest, json, strutils]
import tianguis/[cli, attestation]

suite "cli attest-statement":
  test "emits exactly buildEntryStatement's JSON for the same inputs":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt",
      name: "chronos",
      version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    let r = attestStatementResult(args)
    check r.code == 0
    check r.stderr == ""
    let expected = buildEntryStatement(
      args.namespace, args.name, args.version, args.contentHash,
      args.attestationKind, args.signedBy,
    )
    check r.stdout == expected
    # sanity: it really is the S3 subject shape milpa's verifier expects
    let j = parseJson(r.stdout)
    check j["subject"][0]["name"].getStr == "pkg:tianguis/coreyleavitt/chronos@0.5.0"
    check j["subject"][0]["digest"]["sha256"].getStr == "a".repeat(64)

  test "missing --namespace fails: exit 4, empty stdout, non-empty stderr":
    let args = AttestStatementArgs(
      name: "chronos", version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    let r = attestStatementResult(args)
    check r.code == 4
    check r.stdout == ""
    check r.stderr.len > 0

  test "missing --name fails: exit 4":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    check attestStatementResult(args).code == 4

  test "missing --version fails: exit 4":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    check attestStatementResult(args).code == 4

  test "missing --content-hash fails: exit 4":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos", version: "0.5.0",
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    check attestStatementResult(args).code == 4

  test "missing --attestation-kind fails: exit 4":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos", version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      signedBy: "https://vendor-bot.example/identity",
    )
    check attestStatementResult(args).code == 4

  test "missing --signed-by fails: exit 4":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos", version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
    )
    check attestStatementResult(args).code == 4

  test "all args empty: exit 4, no crash":
    check attestStatementResult(AttestStatementArgs()).code == 4

  test "cmdAttestStatement (I/O wrapper) mirrors the pure core's exit code":
    let goodArgs = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos", version: "0.5.0",
      contentHash: "dag-sha256:" & "a".repeat(64),
      attestationKind: "milpa-vendored",
      signedBy: "https://vendor-bot.example/identity",
    )
    check cmdAttestStatement(goodArgs) == 0
    check cmdAttestStatement(AttestStatementArgs()) == 4

  test "determinism: same inputs via the CLI core produce byte-identical output":
    let args = AttestStatementArgs(
      namespace: "coreyleavitt", name: "chronos", version: "0.5.0",
      contentHash: "dag-sha256:" & "b".repeat(64),
      attestationKind: "author-signed",
      signedBy: "corey@example.com",
    )
    let a = attestStatementResult(args)
    let b = attestStatementResult(args)
    check a.stdout == b.stdout
