## CLI tests for `tianguis vendor --bundle-pins=<path>` — the apply-only
## pass (rfc-attestation-delivery.handoff.md S7b; tianguis#42) that merges
## previously-minted bundle pins into index.kdl with NO network / Driver
## involved at all (unlike a normal `tianguis vendor` pass, which is not
## independently CLI-tested for the same reason it always hard-codes the
## real Driver — see test_vendor_orchestrate.nim for the Driver-injected
## coverage of the candidate-emission side of this flow).

import std/[unittest, os, strutils, tempfiles]
import tianguis/[model, kdl_io]
import tianguis/cli

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-vendor-bundle-pins-", "")
  try:
    body
  finally:
    removeDir(name)

const epochKdl = "schema_version 1\nattestation-epoch \"2026-06-01T00:00:00Z\"\n"

proc pinsJson(pin: string, contentHash = "sha256:abcdef"): string =
  """
[
  {
    "namespace": "github.com/coreyleavitt",
    "name": "chronos",
    "version": "0.5.0",
    "content_hash": "$1",
    "upstream": "https://github.com/coreyleavitt/chronos",
    "commit_sha": "deadbeef1234567",
    "git_ref": "v0.5.0",
    "published_at": "2026-06-15T00:00:00Z",
    "bundle_pin": "$2"
  }
]
""" % [contentHash, pin]

suite "cli vendor --bundle-pins":
  test "applies a valid pins file: index.kdl gains the entry with bundle sha256=":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", epochKdl)
      let pin = "a".repeat(64)
      let pinsPath = tmp / "pins.json"
      writeFile(pinsPath, pinsJson(pin))

      let code = cmdVendor(tmp, bundlePinsPath = pinsPath)
      check code == 0

      let kdlText = readFile(tmp / "index.kdl")
      check ("bundle sha256=\"" & pin & "\"") in kdlText
      let parsed = parseKdl(kdlText)
      check parsed.isOk
      let idx = parsed.get
      check idx.packages.len == 1
      check idx.packages[0].name == "chronos"
      let v = idx.packages[0].versions[0]
      check v.contentHash == "sha256:abcdef"
      check v.bundlePin.isSome
      check v.bundlePin.get == pin

  test "malformed pins file (missing bundle_pin) is rejected: exit 1, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", epochKdl)
      let original = readFile(tmp / "index.kdl")
      writeFile(tmp / "pins.json", """[{"namespace": "n", "name": "p",
        "version": "1.0.0", "content_hash": "sha256:a", "upstream": "u",
        "commit_sha": "c", "git_ref": "g", "published_at": "t"}]""")

      let code = cmdVendor(tmp, bundlePinsPath = tmp / "pins.json")
      check code == 1
      check readFile(tmp / "index.kdl") == original

  test "missing --bundle-pins file path is rejected: exit 1, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", epochKdl)
      let original = readFile(tmp / "index.kdl")

      let code = cmdVendor(tmp, bundlePinsPath = tmp / "does-not-exist.json")
      check code == 1
      check readFile(tmp / "index.kdl") == original

  test "--bundle-pins takes precedence over --emit-bundle-candidates: no candidates file written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", epochKdl)
      let pin = "b".repeat(64)
      writeFile(tmp / "pins.json", pinsJson(pin))
      let candidatesPath = tmp / "candidates.json"

      let code = cmdVendor(tmp,
        emitCandidatesPath = candidatesPath,
        bundlePinsPath     = tmp / "pins.json",
      )
      check code == 0
      check not fileExists(candidatesPath)
      check ("bundle sha256=\"" & pin & "\"") in readFile(tmp / "index.kdl")

  test "re-applying the same pins file twice is idempotent":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", epochKdl)
      let pin = "e".repeat(64)
      writeFile(tmp / "pins.json", pinsJson(pin))

      check cmdVendor(tmp, bundlePinsPath = tmp / "pins.json") == 0
      let afterFirst = readFile(tmp / "index.kdl")
      check cmdVendor(tmp, bundlePinsPath = tmp / "pins.json") == 0
      let afterSecond = readFile(tmp / "index.kdl")
      check afterFirst == afterSecond
