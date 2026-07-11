## Content-addressed bundle store tests (rfc-attestation-delivery.handoff.md S4).
##
## milpa fetches `<index_base_url>/attestation/<sha256_hex>.bundle` — a FLAT
## file tree keyed by the sha256 of the bundle BYTES. `writeBundle` is the
## write-side counterpart: bytes in, pin (+ file on disk) out.

import std/[unittest, os, strutils, tempfiles]
import nimcrypto/[hash, sha2]
import tianguis/[bundlestore]

template withTempDir(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-bundlestore-", "")
  try:
    body
  finally:
    removeDir(name)

proc referenceHex(bytes: string): string =
  toLowerAscii($sha256.digest(bytes))

suite "bundlestore":
  test "writeBundle writes attestation/<hex>.bundle and returns the lowercase sha256 hex":
    withTempDir(tmp):
      let bytes = "fake DSSE bundle bytes"
      let pin = writeBundle(tmp, bytes)

      check pin == referenceHex(bytes)
      check pin.len == 64
      for c in pin:
        check c in {'0'..'9', 'a'..'f'}

      let dest = tmp / (pin & ".bundle")
      check fileExists(dest)
      check readFile(dest) == bytes

  test "idempotent: writing identical bytes twice returns the same pin and one file":
    withTempDir(tmp):
      let bytes = "same bytes every time"
      let pin1 = writeBundle(tmp, bytes)
      let pin2 = writeBundle(tmp, bytes)

      check pin1 == pin2

      var bundleFiles: seq[string] = @[]
      for f in walkFiles(tmp / "*.bundle"):
        bundleFiles.add(f)
      check bundleFiles.len == 1
      check readFile(tmp / (pin1 & ".bundle")) == bytes

  test "different bytes produce different pins and both files coexist":
    withTempDir(tmp):
      let pinA = writeBundle(tmp, "bundle A")
      let pinB = writeBundle(tmp, "bundle B")

      check pinA != pinB
      check fileExists(tmp / (pinA & ".bundle"))
      check fileExists(tmp / (pinB & ".bundle"))
      check readFile(tmp / (pinA & ".bundle")) == "bundle A"
      check readFile(tmp / (pinB & ".bundle")) == "bundle B"

  test "no temp/partial files remain after a successful write":
    withTempDir(tmp):
      discard writeBundle(tmp, "clean write")

      var leftovers: seq[string] = @[]
      for f in walkFiles(tmp / "*.tmp"):
        leftovers.add(f)
      check leftovers.len == 0
