#!/usr/bin/env python3
"""Sign an in-toto statement (stdin) into a Sigstore DSSE bundle (stdout).

rfc-attestation-delivery.handoff.md S7c — the ONE CI-only seam in the
minting pipeline. Everything upstream of this script (the S3 statement
bytes) is produced by a single source of truth, the Nim `tianguis
attest-statement` subcommand (src/tianguis/cli.nim); this script never
re-derives the statement, it only signs the exact bytes it's given.

MUST run inside a GitHub Actions workflow. `detect_credential()` picks up
the ambient GH-Actions OIDC token, whose Fulcio-issued certificate records
issuer `https://token.actions.githubusercontent.com`. milpa's per-entry
attestation verifier HARDCODES that exact issuer as the only accepted
signer for both `milpa-vendored` and `author-signed` entries
(impls/python/milpa/entry_trust.py — see the handoff's "HARD CONSTRAINT"
note). A bundle signed from a local OAuth session (github.com / google /
etc. issuer) verifies fine against Sigstore's transparency log in
isolation, but fails milpa's gate with `SignerMismatch` — a different
issuer, not merely a different identity. There is no local-signing path
that satisfies milpa; this script is not runnable outside CI by design.

Usage (piped, no arguments):
    tianguis attest-statement --namespace=... --name=... --version=... \\
        --content-hash=... --attestation-kind=... --signed-by=... \\
      | python3 scripts/sign_statement.py > bundle.json

Assumptions about the sigstore-python API (installed version 4.3.0,
verified against a throwaway venv while writing this — the handoff's
RESOLVED recipe names this exact library + version):
  - `sigstore.dsse.Statement(contents=<bytes>)` accepts the *raw* statement
    bytes and preserves them byte-for-byte (it validates conformance via
    pydantic but signs the original `contents`, never a re-serialization) —
    this is what makes stdin->Statement->sign_dsse byte-exact.
  - `sigstore.models.ClientTrustConfig.production()` +
    `sigstore.sign.SigningContext.from_trust_config(...)` is the documented
    entry point (see sigstore.sign's module docstring example).
  - `sigstore.oidc.detect_credential()` returns `str | None` (a raw JWT),
    NOT an `IdentityToken` — it must be wrapped via
    `sigstore.oidc.IdentityToken(raw_token)` before use.
  - `SigningContext.signer(identity_token)` is a context manager yielding a
    `Signer`; `Signer.sign_dsse(statement) -> Bundle`.
  - `Bundle.to_json()` serializes the Sigstore Bundle (media type
    `application/vnd.dev.sigstore.bundle.v0.3+json`, i.e. BUNDLE_0_3) that
    `SigstoreEntryVerifier` (milpa, both impls) loads as-is.
"""
from __future__ import annotations

import sys

from sigstore.dsse import Statement
from sigstore.models import ClientTrustConfig
from sigstore.oidc import IdentityToken, detect_credential
from sigstore.sign import SigningContext


def sign_dsse(statement_bytes: bytes) -> str:
    """Sign `statement_bytes` (a raw in-toto Statement JSON, byte-for-byte
    as produced by `tianguis attest-statement`) under ambient GH-Actions
    OIDC and return the resulting Sigstore Bundle as JSON text.

    NOT locally testable: talks to Fulcio (cert issuance) and Rekor
    (transparency log inclusion) over the network, and raises immediately
    if no ambient OIDC credential is present (see module docstring).
    """
    raw_token = detect_credential()
    if raw_token is None:
        raise RuntimeError(
            "no ambient OIDC credential detected; this script must run "
            "inside a GitHub Actions workflow with `id-token: write` "
            "permission, not on a local machine (see module docstring)"
        )
    identity_token = IdentityToken(raw_token)

    trust_config = ClientTrustConfig.production()
    context = SigningContext.from_trust_config(trust_config)
    statement = Statement(contents=statement_bytes)

    with context.signer(identity_token) as signer:
        bundle = signer.sign_dsse(statement)

    return bundle.to_json()


def main() -> int:
    statement_bytes = sys.stdin.buffer.read()
    if not statement_bytes.strip():
        print(
            "sign_statement: empty stdin; expected an in-toto statement "
            "JSON on stdin (pipe `tianguis attest-statement` output in)",
            file=sys.stderr,
        )
        return 4
    try:
        bundle_json = sign_dsse(statement_bytes)
    except RuntimeError as exc:
        print(f"sign_statement: {exc}", file=sys.stderr)
        return 3
    sys.stdout.write(bundle_json)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
