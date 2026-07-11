"""Tests for site/scripts/build.py.

Run: python3 -m pytest site/scripts/test_build.py -q
(needs `markdown` installed — see site/scripts/requirements.txt; build.py
imports it at module scope even though these tests only exercise the
attestation-copy path).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build  # noqa: E402


def test_copies_attestation_tree_byte_identical(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    build_dir = tmp_path / "_build"
    att_src = repo_root / "attestation"
    att_src.mkdir(parents=True)
    hex_name = "a" * 64 + ".bundle"
    bundle_bytes = b"\x00\x01DSSE-envelope-bytes-not-real-json"
    (att_src / hex_name).write_bytes(bundle_bytes)
    build_dir.mkdir()

    build.copy_attestation_tree(repo_root, build_dir)

    dest = build_dir / "attestation" / hex_name
    assert dest.exists()
    assert dest.read_bytes() == bundle_bytes


def test_absent_attestation_tree_is_not_an_error(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    build_dir = tmp_path / "_build"
    repo_root.mkdir()
    build_dir.mkdir()

    build.copy_attestation_tree(repo_root, build_dir)  # must not raise

    assert not (build_dir / "attestation").exists()


def test_stale_bundle_not_in_source_does_not_survive_rebuild(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    build_dir = tmp_path / "_build"
    att_src = repo_root / "attestation"
    att_src.mkdir(parents=True)
    current_name = "b" * 64 + ".bundle"
    (att_src / current_name).write_bytes(b"current bundle")

    # Simulate a previous build's output containing a bundle that has since
    # been removed/rotated out of the source tree.
    stale_dest = build_dir / "attestation"
    stale_dest.mkdir(parents=True)
    stale_name = "c" * 64 + ".bundle"
    (stale_dest / stale_name).write_bytes(b"stale bundle")

    build.copy_attestation_tree(repo_root, build_dir)

    assert (build_dir / "attestation" / current_name).exists()
    assert not (build_dir / "attestation" / stale_name).exists()
