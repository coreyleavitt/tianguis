"""Tests for scripts/mint_bundle.py — the non-signing parts only.

Run: python3 -m pytest scripts/test_mint_bundle.py -q
(needs `sigstore` installed — see scripts/requirements.txt; mint_bundle.py
imports sign_statement.sign_dsse at module scope even though these tests
never call it, since real signing needs a GH-Actions OIDC token and is not
locally testable — see sign_statement.py's module docstring).
"""
from __future__ import annotations

import hashlib
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mint_bundle  # noqa: E402


def _fake_tianguis_bin(tmp_path: Path, stdout: bytes) -> str:
    """A stand-in for the compiled `tianguis` binary: a shell script that
    ignores its args and echoes fixed bytes to stdout, so fetch_statement
    can be exercised without a real Nim build. Bytes are base64-encoded in
    the script so arbitrary content survives shell quoting untouched.
    """
    import base64

    script = tmp_path / "fake-tianguis"
    b64 = base64.b64encode(stdout).decode("ascii")
    script.write_text(f"#!/bin/sh\necho '{b64}' | base64 -d\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return str(script)


def test_fetch_statement_returns_stdout_verbatim_minus_trailing_newline(tmp_path: Path) -> None:
    stmt = b'{"_type":"https://in-toto.io/Statement/v1","subject":[]}\n'
    bin_path = _fake_tianguis_bin(tmp_path, stmt)
    result = mint_bundle.fetch_statement(
        bin_path, "coreyleavitt", "chronos", "0.5.0",
        "dag-sha256:" + "a" * 64, "milpa-vendored",
        "https://vendor-bot.example/identity",
    )
    assert result == stmt.rstrip(b"\n")


def test_sha256_hex_matches_hashlib_directly() -> None:
    data = b"hello world"
    assert mint_bundle.sha256_hex(data) == hashlib.sha256(data).hexdigest()
    # lowercase, 64 hex chars
    digest = mint_bundle.sha256_hex(data)
    assert len(digest) == 64
    assert digest == digest.lower()
    int(digest, 16)  # raises if not valid hex


def test_bundle_path_is_flat_hex_dot_bundle(tmp_path: Path) -> None:
    hex_digest = "b" * 64
    p = mint_bundle.bundle_path(tmp_path, hex_digest)
    assert p == tmp_path / (hex_digest + ".bundle")
    assert p.parent == tmp_path  # flat tree, no directory-per-hash sharding


def test_write_bundle_writes_content_addressed_file_and_returns_pin(tmp_path: Path) -> None:
    attestation_dir = tmp_path / "attestation"
    bundle_bytes = b'{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}'
    pin = mint_bundle.write_bundle(attestation_dir, bundle_bytes)

    assert pin == hashlib.sha256(bundle_bytes).hexdigest()
    dest = attestation_dir / f"{pin}.bundle"
    assert dest.exists()
    assert dest.read_bytes() == bundle_bytes
    # no stray temp files left behind
    assert list(attestation_dir.iterdir()) == [dest]


def test_write_bundle_is_idempotent_on_identical_bytes(tmp_path: Path) -> None:
    attestation_dir = tmp_path / "attestation"
    bundle_bytes = b"identical bundle bytes"
    pin1 = mint_bundle.write_bundle(attestation_dir, bundle_bytes)
    dest = attestation_dir / f"{pin1}.bundle"
    mtime1 = dest.stat().st_mtime_ns

    pin2 = mint_bundle.write_bundle(attestation_dir, bundle_bytes)
    mtime2 = dest.stat().st_mtime_ns

    assert pin1 == pin2
    assert mtime1 == mtime2  # second write was skipped, not re-touched
    assert dest.read_bytes() == bundle_bytes


def test_write_bundle_creates_attestation_dir_if_absent(tmp_path: Path) -> None:
    attestation_dir = tmp_path / "nested" / "attestation"
    assert not attestation_dir.exists()
    mint_bundle.write_bundle(attestation_dir, b"x")
    assert attestation_dir.is_dir()


def test_different_bytes_produce_different_pins_both_persisted(tmp_path: Path) -> None:
    attestation_dir = tmp_path / "attestation"
    pin_a = mint_bundle.write_bundle(attestation_dir, b"bundle A")
    pin_b = mint_bundle.write_bundle(attestation_dir, b"bundle B")
    assert pin_a != pin_b
    assert (attestation_dir / f"{pin_a}.bundle").read_bytes() == b"bundle A"
    assert (attestation_dir / f"{pin_b}.bundle").read_bytes() == b"bundle B"
