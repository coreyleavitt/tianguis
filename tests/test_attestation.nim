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
