## CLI tests for `tianguis show-preepoch-set` — read-only enumeration of the
## D-Watermark pre-epoch set S and its commitment C (milpa
## `docs/rfc-attestation-v1-normative.md` §6 S-EpochCommitment). Dual-purpose
## single source of truth: both the human dry-run diff
## (`cmd_set_epoch_commitment`) and the minting workflow's machine payload
## shell out to this same result.

import std/[unittest, os, json, tempfiles]
import tianguis/[model, kdl_io, cli, preepoch_commitment]

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-show-preepoch-", "")
  try:
    body
  finally:
    removeDir(name)

suite "cli show-preepoch-set":
  test "prints canonically-sorted identities plus a matching commitment":
    withTempProject(tmp):
      let idx = Index(schemaVersion: 1, packages: @[
        Package(name: "pkg", namespace: "ns", upstream: "https://x", versions: @[
          Version(version: "1.0.0", contentHash: "sha256:aa",
            attestation: "milpa-vendored", signedBy: "milpa-bot",
            publishedAt: "2026-01-01T00:00:00Z"),
        ]),
      ])
      writeFile(tmp / "index.kdl", formatKdl(idx))
      let r = showPreepochSetResult(tmp)
      check r.code == 0
      let j = parseJson(r.stdout)
      check j["identities"].len == 1
      check j["identities"][0]["namespace"].getStr == "ns"
      check j["identities"][0]["name"].getStr == "pkg"
      check j["identities"][0]["version"].getStr == "1.0.0"
      check j["identities"][0]["content_hash"].getStr == "sha256:aa"
      let expected = commitmentDigest(enumerateCurrentSet(idx))
      check j["commitment"].getStr == expected

  test "empty index prints an empty identities array and the empty-set commitment":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(Index(schemaVersion: 1, packages: @[])))
      let r = showPreepochSetResult(tmp)
      check r.code == 0
      let j = parseJson(r.stdout)
      check j["identities"].len == 0
      check j["commitment"].getStr == commitmentDigest(@[])

  test "never mutates index.kdl":
    withTempProject(tmp):
      let idx = Index(schemaVersion: 1, packages: @[])
      writeFile(tmp / "index.kdl", formatKdl(idx))
      let original = readFile(tmp / "index.kdl")
      discard showPreepochSetResult(tmp)
      check readFile(tmp / "index.kdl") == original

  test "missing index.kdl: exit 1":
    withTempProject(tmp):
      let r = showPreepochSetResult(tmp)
      check r.code == 1

  test "malformed index.kdl: exit 1":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "not valid kdl {{{")
      let r = showPreepochSetResult(tmp)
      check r.code == 1

  test "cmdShowPreepochSet (I/O wrapper) mirrors the pure core's exit code":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(Index(schemaVersion: 1, packages: @[])))
      check cmdShowPreepochSet(tmp) == 0
    withTempProject(tmp2):
      check cmdShowPreepochSet(tmp2) == 1
