#!/usr/bin/env python3
"""Mint one per-entry attestation bundle end-to-end (rfc-attestation-
delivery.handoff.md S7c orchestration wrapper).

Wires together the three pieces of the minting pipeline:

  1. `tianguis attest-statement` (the Nim CLI, S7c) — the single source of
     truth for the S3 in-toto statement bytes. This script shells out to
     the compiled binary rather than re-deriving the statement in Python.
  2. `sign_statement.sign_dsse` (this same S7c slice) — signs those exact
     bytes under ambient GH-Actions OIDC via the sigstore-python LIBRARY.
     CI-only; see sign_statement.py's module docstring for why cosign CLI /
     local signing cannot satisfy milpa's verifier.
  3. A content-addressed bundle write: sha256 of the bundle bytes -> write
     `<attestation_dir>/<hex>.bundle` -> return the pin. Deliberately
     faithful to `src/tianguis/bundlestore.nim`'s `writeBundle` (S4): flat
     tree (no directory-per-hash), lowercase hex filename stem, idempotent
     (the filename IS the hash of the content, so an existing file by that
     name already holds those exact bytes — a second write is a no-op),
     atomic (temp file + rename, never a partial `.bundle` visible to a
     concurrent reader).

Steps 1 and 3 (statement fetch via subprocess, path derivation, hashing,
writing) have no crypto dependency and are exercised directly by
scripts/test_mint_bundle.py without needing real Sigstore signing. Only
step 2 needs a real GH-Actions OIDC token.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# `sign_statement` is a sibling module in this directory; running this file
# directly (`python3 scripts/mint_bundle.py`) puts scripts/ on sys.path[0]
# automatically, same convention as site/scripts/test_build.py's import of
# `build`.
from sign_statement import sign_dsse


def fetch_statement(
    tianguis_bin: str,
    namespace: str,
    name: str,
    version: str,
    content_hash: str,
    attestation_kind: str,
    signed_by: str,
) -> bytes:
    """Shell out to the compiled `tianguis attest-statement` binary and
    return its stdout bytes verbatim (minus the trailing newline `echo`
    adds) — the single source of truth for the statement bytes; this
    function never re-derives them in Python (S7c).
    """
    result = subprocess.run(
        [
            tianguis_bin,
            "attest-statement",
            f"--namespace={namespace}",
            f"--name={name}",
            f"--version={version}",
            f"--content-hash={content_hash}",
            f"--attestation-kind={attestation_kind}",
            f"--signed-by={signed_by}",
        ],
        capture_output=True,
        check=True,
    )
    return result.stdout.rstrip(b"\n")


def sha256_hex(data: bytes) -> str:
    """Lowercase 64-hex sha256 — matches bundlestore.nim's `sha256Hex`
    exactly: same algorithm, same lowercase-hex convention milpa's `bundle
    sha256=` pin (and the `<hex>.bundle` filename stem) requires.
    """
    return hashlib.sha256(data).hexdigest()


def bundle_path(attestation_dir: Path, hex_digest: str) -> Path:
    """The flat-tree path for a given pin — mirrors bundlestore.nim's
    `bundlePath`: `<attestation_dir>/<hex>.bundle`, no directory sharding.
    """
    return attestation_dir / f"{hex_digest}.bundle"


def write_bundle(attestation_dir: Path, bundle_bytes: bytes) -> str:
    """Write `bundle_bytes` into the content-addressed tree and return the
    pin (lowercase sha256 hex). Idempotent + atomic, mirroring
    bundlestore.nim's `writeBundle`: because the filename IS the hash of
    the content, an existing `<hex>.bundle` is provably already exactly
    these bytes, so a second write for the same bytes is skipped entirely
    rather than re-opened/re-compared/re-written. The write itself goes
    through a temp-file-then-rename so a concurrent reader (milpa fetching
    mid-publish) can never observe a partially-written `.bundle` file.
    """
    hex_digest = sha256_hex(bundle_bytes)
    attestation_dir.mkdir(parents=True, exist_ok=True)
    dest = bundle_path(attestation_dir, hex_digest)
    if not dest.exists():
        fd, tmp_path = tempfile.mkstemp(dir=str(attestation_dir), prefix=".tmp-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(bundle_bytes)
            os.rename(tmp_path, dest)
        except BaseException:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
            raise
    return hex_digest


def mint(
    tianguis_bin: str,
    attestation_dir: Path,
    namespace: str,
    name: str,
    version: str,
    content_hash: str,
    attestation_kind: str,
    signed_by: str,
) -> str:
    """Full mint: statement -> sign -> write -> pin. Returns the pin.

    The only step here that isn't locally smoke-testable is `sign_dsse`
    (CI-only OIDC signing); everything else is plain subprocess + hashing +
    filesystem I/O.
    """
    statement_bytes = fetch_statement(
        tianguis_bin, namespace, name, version, content_hash,
        attestation_kind, signed_by,
    )
    bundle_json = sign_dsse(statement_bytes)
    return write_bundle(attestation_dir, bundle_json.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tianguis-bin", default="./tianguis",
        help="path to the compiled tianguis binary (default: ./tianguis)",
    )
    parser.add_argument(
        "--attestation-dir", default="attestation",
        help="content-addressed bundle tree root (default: ./attestation)",
    )
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--content-hash", required=True)
    parser.add_argument("--attestation-kind", required=True)
    parser.add_argument("--signed-by", required=True)
    args = parser.parse_args()

    pin = mint(
        args.tianguis_bin,
        Path(args.attestation_dir),
        args.namespace,
        args.name,
        args.version,
        args.content_hash,
        args.attestation_kind,
        args.signed_by,
    )
    print(pin)
    return 0


if __name__ == "__main__":
    sys.exit(main())
