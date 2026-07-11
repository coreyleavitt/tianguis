## Content-addressed store for per-entry attestation bundles
## (rfc-attestation-delivery.handoff.md S4; per-entry-attestation.md §7).
##
## milpa fetches `<index_base_url>/attestation/<sha256_hex>.bundle` — a FLAT
## file tree (NOT directory-per-hash), where `<sha256_hex>` is the sha256 of
## the bundle BYTES and must be exactly what the `bundle sha256=` pin (S1,
## `kdl_io.isHex64`) carries. This module is the write-side counterpart to
## that read: bytes in, (pin, file on disk) out.
##
## Idempotent by construction: because the filename IS the hash of the
## content, a `<hex>.bundle` file that already exists on disk is provably
## already the requested bytes — a second write for the same bytes is a
## pure no-op, never a re-open/re-compare/re-write.

import std/[os, strutils]
import nimcrypto/[hash, sha2]
import ./fileutil

proc sha256Hex*(bundleBytes: string): string =
  ## Lowercase 64-hex sha256 of `bundleBytes` — the exact pin format milpa
  ## validates (`^[0-9a-f]{64}$`, `kdl_io.isHex64`) and the exact filename
  ## stem tianguis serves at `attestation/<hex>.bundle`. nimcrypto's `$`
  ## on an `MDigest` emits uppercase hex by default (opt-in lowercase is a
  ## global compile-time flag we don't otherwise set), so lowercase it
  ## explicitly here rather than depend on a build flag.
  toLowerAscii($sha256.digest(bundleBytes))

proc bundlePath*(attestationDir, hex: string): string =
  ## The flat-tree path for a given pin: `<attestationDir>/<hex>.bundle`.
  attestationDir / (hex & ".bundle")

proc writeBundle*(attestationDir: string, bundleBytes: string): string =
  ## Write `bundleBytes` into the content-addressed `attestation/` tree and
  ## return the pin (lowercase sha256 hex) that both names the file and
  ## becomes the `bundle sha256=` field milpa parses (S1).
  ##
  ## Content-addressed ⇒ idempotent: if `<hex>.bundle` already exists, its
  ## content already IS `bundleBytes` (the name is the hash of the content),
  ## so we skip the write entirely rather than re-touch the file.
  ##
  ## Atomic on the write path: goes through `fileutil.atomicWrite` (temp
  ## sibling + rename), so a reader (milpa fetching mid-publish) can never
  ## observe a partially-written `.bundle` file.
  let hex = sha256Hex(bundleBytes)
  createDir(attestationDir)
  let dest = bundlePath(attestationDir, hex)
  if not fileExists(dest):
    atomicWrite(dest, bundleBytes)
  hex
