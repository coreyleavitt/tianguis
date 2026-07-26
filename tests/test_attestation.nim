## §1 in-toto statement builder tests — the bytes the author/bot signs
## (rfc-attestation-delivery.handoff.md S3).
##
## `buildEntryStatement` is a PURE function: no I/O, no crypto. It must
## produce the exact subject shape milpa's `entry_trust.build_entry_subject`
## (impls/python/milpa/entry_trust.py) verifies against — `name` and
## `digest.sha256` are equality-checked by milpa's gate stages 3/4, so this
## is a byte-format contract, not a style choice.

import std/[unittest, json, strutils]
import tianguis/attestation

suite "buildEntryStatement":
  test "subject[0].name matches milpa's pkg:tianguis/<ns>/<name>@<version> coordinate":
    let stmt = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & "a".repeat(64),
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    let j = parseJson(stmt)
    check j["subject"][0]["name"].getStr == "pkg:tianguis/coreyleavitt/chronos@0.5.0"

  test "subject[0].digest.sha256 strips the dag-sha256 scheme":
    let hexDigest = "b".repeat(64)
    let stmt = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & hexDigest,
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    let j = parseJson(stmt)
    check j["subject"][0]["digest"]["sha256"].getStr == hexDigest

  test "subject[0].digest.sha256 works with a bare hex (no scheme prefix)":
    let hexDigest = "c".repeat(64)
    let stmt = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = hexDigest,
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    let j = parseJson(stmt)
    check j["subject"][0]["digest"]["sha256"].getStr == hexDigest

  test "statement is a valid in-toto Statement: _type + single-element subject array":
    let stmt = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & "d".repeat(64),
      attestationKind = "author-signed",
      signedBy = "corey@example.com",
    )
    let j = parseJson(stmt)
    check j["_type"].getStr == "https://in-toto.io/Statement/v1"
    check j["subject"].kind == JArray
    check j["subject"].len == 1
    check j.hasKey("predicateType")
    check j.hasKey("predicate")

  test "determinism: two calls with identical inputs produce byte-identical output":
    let a = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & "e".repeat(64),
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    let b = buildEntryStatement(
      namespace = "coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & "e".repeat(64),
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    check a == b

  test "a namespace containing a slash produces the exact milpa purl coordinate":
    let stmt = buildEntryStatement(
      namespace = "github.com/coreyleavitt",
      name = "chronos",
      version = "0.5.0",
      contentHash = "dag-sha256:" & "f".repeat(64),
      attestationKind = "milpa-vendored",
      signedBy = "https://vendor-bot.example/identity",
    )
    let j = parseJson(stmt)
    check j["subject"][0]["name"].getStr ==
      "pkg:tianguis/github.com/coreyleavitt/chronos@0.5.0"

suite "extractStatementSubject":
  ## The parsing half of the S8 subject-binding check (add-entry
  ## --entry-statement). This is UNTRUSTED-input parsing (the statement
  ## travels over repository_dispatch before any crypto check runs), so
  ## every malformed-shape case must return Err, never raise.

  test "round-trips buildEntryStatement's own output":
    let stmt = buildEntryStatement(
      namespace = "github.com/coreyleavitt", name = "chronos", version = "0.5.0",
      contentHash = "dag-sha256:" & "a".repeat(64),
      attestationKind = "author-signed", signedBy = "https://example/identity",
    )
    let r = extractStatementSubject(stmt)
    check r.isOk
    check r.get.name == "pkg:tianguis/github.com/coreyleavitt/chronos@0.5.0"
    check r.get.digestSha256 == "a".repeat(64)

  test "malformed JSON is Err, not a raised exception":
    let r = extractStatementSubject("not json at all")
    check r.isErr

  test "empty string is Err":
    let r = extractStatementSubject("")
    check r.isErr

  test "JSON object with no 'subject' key is Err":
    let r = extractStatementSubject("""{"_type": "https://in-toto.io/Statement/v1"}""")
    check r.isErr

  test "'subject' present but empty array is Err":
    let r = extractStatementSubject("""{"subject": []}""")
    check r.isErr

  test "subject[0] missing 'name' is Err":
    let r = extractStatementSubject("""{"subject": [{"digest": {"sha256": "abc"}}]}""")
    check r.isErr

  test "subject[0] missing 'digest' is Err":
    let r = extractStatementSubject("""{"subject": [{"name": "pkg:x"}]}""")
    check r.isErr

  test "subject[0].digest missing 'sha256' key is Err":
    let r = extractStatementSubject("""{"subject": [{"name": "pkg:x", "digest": {"sha512": "abc"}}]}""")
    check r.isErr

  test "a JSON array (not object) at top level is Err":
    let r = extractStatementSubject("""[1, 2, 3]""")
    check r.isErr

suite "buildIndexStatement":
  ## The whole-index counterpart to `buildEntryStatement` (milpa
  ## `docs/rfc-registry-trust-federation.md` §4/§7.3 — TNG-INDEX-BUNDLE-
  ## MISSING). milpa's whole-index verifier
  ## (`impls/python/milpa/index_trust.py::_check_dsse_payload_digest`)
  ## checks ONLY `subject[0].digest.sha256`; `name` and the predicate are
  ## never inspected, so only the digest is a byte-format contract.

  test "subject[0].digest.sha256 is exactly the caller-supplied digest, unmodified":
    let hexDigest = "a".repeat(64)
    let stmt = buildIndexStatement(hexDigest, "https://vendor-bot.example/identity")
    let j = parseJson(stmt)
    check j["subject"][0]["digest"]["sha256"].getStr == hexDigest

  test "no dag-sha256 scheme stripping (unlike buildEntryStatement) — a scheme-prefixed" &
      " input is passed through verbatim, not silently reinterpreted":
    let withScheme = "dag-sha256:" & "b".repeat(64)
    let stmt = buildIndexStatement(withScheme, "https://vendor-bot.example/identity")
    let j = parseJson(stmt)
    check j["subject"][0]["digest"]["sha256"].getStr == withScheme

  test "subject[0].name is the descriptive 'index.kdl' literal":
    let stmt = buildIndexStatement("c".repeat(64), "https://vendor-bot.example/identity")
    let j = parseJson(stmt)
    check j["subject"][0]["name"].getStr == "index.kdl"

  test "statement is a valid in-toto Statement: _type + single-element subject array":
    let stmt = buildIndexStatement("d".repeat(64), "https://vendor-bot.example/identity")
    let j = parseJson(stmt)
    check j["_type"].getStr == "https://in-toto.io/Statement/v1"
    check j["subject"].kind == JArray
    check j["subject"].len == 1
    check j.hasKey("predicateType")
    check j.hasKey("predicate")

  test "predicate.signed_by carries the caller-supplied identity":
    let stmt = buildIndexStatement("e".repeat(64), "https://github.com/coreyleavitt/tianguis/.github/workflows/attest-index.yaml@refs/heads/main")
    let j = parseJson(stmt)
    check j["predicate"]["signed_by"].getStr ==
      "https://github.com/coreyleavitt/tianguis/.github/workflows/attest-index.yaml@refs/heads/main"

  test "determinism: two calls with identical inputs produce byte-identical output":
    let a = buildIndexStatement("f".repeat(64), "https://vendor-bot.example/identity")
    let b = buildIndexStatement("f".repeat(64), "https://vendor-bot.example/identity")
    check a == b
