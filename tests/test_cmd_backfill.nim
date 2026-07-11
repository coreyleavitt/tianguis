## CLI tests for `tianguis backfill --emit-bundle-candidates=<path>` — the
## full-index sweep (rfc-attestation-delivery.handoff.md S9; tianguis#42)
## that enumerates EXISTING pinless-vendored entries and writes them in the
## same `BundleCandidate` JSON shape S7b uses, so the EXISTING
## `tianguis vendor --bundle-pins=<path>` apply path consumes them
## unchanged. Mirrors test_cmd_vendor_bundle_pins.nim's withTempProject
## pattern; fixture files are built via `formatKdl` over typed model
## objects (test_cmd_migrate.nim's precedent), never hand-transcribed KDL.

import std/[unittest, os, options, tempfiles, json, strutils]
import tianguis/[model, kdl_io]
import tianguis/cli

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-backfill-", "")
  try:
    body
  finally:
    removeDir(name)

proc gitProv(url, gitRef, commitSha: string): Provenance =
  Provenance(kind: pkGit, url: url, gitRef: gitRef, commitSha: commitSha)

proc vendoredVersion(version, contentHash, commitSha: string,
    bundlePin = none(string)): Version =
  Version(
    version: version, contentHash: contentHash,
    attestation: "milpa-vendored",
    signedBy: "https://github.com/coreyleavitt/tianguis (milpa-bot via GH OIDC)",
    publishedAt: "2026-05-02T00:00:00Z",
    provenances: @[gitProv("https://github.com/coreyleavitt/chronos", "v" & version, commitSha)],
    bundlePin: bundlePin,
  )

proc authorSignedVersion(): Version =
  Version(
    version: "1.0.0", contentHash: "sha256:author",
    attestation: "author-signed",
    signedBy: "https://github.com/someauthor/libX/.github/workflows/publish.yaml@refs/heads/main",
    publishedAt: "2026-05-03T00:00:00Z",
    provenances: @[Provenance(kind: pkOci, registry: "ghcr.io", repository: "someauthor/libX", digest: "sha256:zzz")],
  )

proc mixedIndex(): Index =
  Index(schemaVersion: 1, attestationEpoch: some("2026-06-01T00:00:00Z"), packages: @[
    Package(name: "chronos", namespace: "github.com/coreyleavitt",
      upstream: "https://github.com/coreyleavitt/chronos", versions: @[
        vendoredVersion("0.4.0", "sha256:pinned", "aaaa000000000000000000000000000000000000",
          bundlePin = some("a".repeat(64))),
        vendoredVersion("0.5.0", "sha256:pinless", "bbbb000000000000000000000000000000000000"),
      ]),
    Package(name: "libX", namespace: "github.com/someauthor",
      upstream: "https://github.com/someauthor/libX", versions: @[authorSignedVersion()]),
  ])

proc twoEligibleIndex(): Index =
  Index(schemaVersion: 1, attestationEpoch: some("2026-06-01T00:00:00Z"), packages: @[
    Package(name: "chronos", namespace: "github.com/coreyleavitt",
      upstream: "https://github.com/coreyleavitt/chronos", versions: @[
        vendoredVersion("0.5.0", "sha256:one", "bbbb000000000000000000000000000000000000"),
        vendoredVersion("0.6.0", "sha256:two", "cccc000000000000000000000000000000000000"),
      ]),
  ])

suite "cli backfill":
  test "emits a candidate for the pinless-vendored entry only (pinned + author-signed excluded)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let outPath = tmp / "candidates.json"

      let code = cmdBackfill(tmp, emitCandidatesPath = outPath)
      check code == 0

      let arr = parseJson(readFile(outPath))
      check arr.kind == JArray
      check arr.len == 1
      check arr[0]["name"].getStr == "chronos"
      check arr[0]["namespace"].getStr == "github.com/coreyleavitt"
      check arr[0]["version"].getStr == "0.5.0"
      check arr[0]["content_hash"].getStr == "sha256:pinless"
      check arr[0]["commit_sha"].getStr == "bbbb000000000000000000000000000000000000"
      check arr[0]["git_ref"].getStr == "v0.5.0"

  test "empty index (no packages) emits an empty candidates array":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(Index(schemaVersion: 1, packages: @[])))
      let outPath = tmp / "candidates.json"
      check cmdBackfill(tmp, emitCandidatesPath = outPath) == 0
      let arr = parseJson(readFile(outPath))
      check arr.kind == JArray
      check arr.len == 0

  test "missing --emit-bundle-candidates path: exit 1, no file written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let code = cmdBackfill(tmp, emitCandidatesPath = "")
      check code == 1
      check not fileExists(tmp / "candidates.json")

  test "missing index.kdl: exit 1":
    withTempProject(tmp):
      let code = cmdBackfill(tmp, emitCandidatesPath = tmp / "candidates.json")
      check code == 1

  test "malformed index.kdl: exit 1, no candidates file written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "not valid kdl {{{")
      let outPath = tmp / "candidates.json"
      let code = cmdBackfill(tmp, emitCandidatesPath = outPath)
      check code == 1
      check not fileExists(outPath)

  test "--cap bounds the emitted candidates without erroring":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(twoEligibleIndex()))
      let outPath = tmp / "candidates.json"
      let code = cmdBackfill(tmp, emitCandidatesPath = outPath, cap = 1)
      check code == 0
      let arr = parseJson(readFile(outPath))
      check arr.len == 1

  test "--cap larger than the eligible count emits everything":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let outPath = tmp / "candidates.json"
      check cmdBackfill(tmp, emitCandidatesPath = outPath, cap = 1000) == 0
      let arr = parseJson(readFile(outPath))
      check arr.len == 1

  test "cap == 0 means unlimited (default)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let outPath = tmp / "candidates.json"
      check cmdBackfill(tmp, emitCandidatesPath = outPath, cap = 0) == 0
      let arr = parseJson(readFile(outPath))
      check arr.len == 1

  test "end-to-end: emit -> mint -> `backfill --bundle-pins` sets the pin on the EXISTING entry":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let candPath = tmp / "candidates.json"
      check cmdBackfill(tmp, emitCandidatesPath = candPath) == 0

      let pin = "f".repeat(64)
      let cands = parseJson(readFile(candPath))
      var pins = cands
      pins[0]["bundle_pin"] = %pin
      writeFile(tmp / "pins.json", $pins)

      let code = cmdBackfill(tmp, bundlePinsPath = tmp / "pins.json")
      check code == 0
      let kdlText = readFile(tmp / "index.kdl")
      check ("bundle sha256=\"" & pin & "\"") in kdlText
      # the pre-existing already-pinned 0.4.0 entry's pin is untouched
      check ("bundle sha256=\"" & "a".repeat(64) & "\"") in kdlText

  test "`vendor --bundle-pins` (the S7b apply path) silently no-ops on an already-committed " &
      "entry — this is exactly why backfill needs its own apply path, not reuse":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let candPath = tmp / "candidates.json"
      check cmdBackfill(tmp, emitCandidatesPath = candPath) == 0
      let pin = "9".repeat(64)
      let cands = parseJson(readFile(candPath))
      var pins = cands
      pins[0]["bundle_pin"] = %pin
      writeFile(tmp / "pins.json", $pins)

      check cmdVendor(tmp, bundlePinsPath = tmp / "pins.json") == 0
      let kdlText = readFile(tmp / "index.kdl")
      check not (("bundle sha256=\"" & pin & "\"") in kdlText)

  test "--bundle-pins with a missing pins file: exit 1, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let original = readFile(tmp / "index.kdl")
      let code = cmdBackfill(tmp, bundlePinsPath = tmp / "does-not-exist.json")
      check code == 1
      check readFile(tmp / "index.kdl") == original

  test "--bundle-pins takes precedence over --emit-bundle-candidates: no candidates file written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      let pin = "0".repeat(64)
      writeFile(tmp / "pins.json", $(%*[%*{
        "namespace": "github.com/coreyleavitt", "name": "chronos", "version": "0.5.0",
        "content_hash": "sha256:pinless", "upstream": "https://github.com/coreyleavitt/chronos",
        "commit_sha": "bbbb000000000000000000000000000000000000", "git_ref": "v0.5.0",
        "published_at": "2026-05-02T00:00:00Z", "bundle_pin": pin,
      }]))
      let candidatesPath = tmp / "candidates.json"

      let code = cmdBackfill(tmp,
        emitCandidatesPath = candidatesPath,
        bundlePinsPath     = tmp / "pins.json",
      )
      check code == 0
      check not fileExists(candidatesPath)
      check ("bundle sha256=\"" & pin & "\"") in readFile(tmp / "index.kdl")

  test "neither --emit-bundle-candidates nor --bundle-pins given: exit 1":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", formatKdl(mixedIndex()))
      check cmdBackfill(tmp) == 1
