#!/usr/bin/env python3
"""Cryptographically verify an author-signed per-entry attestation bundle
and extract its in-toto statement payload (rfc-attestation-delivery
.handoff.md S8 Layer 2b — the CI-only crypto half of the author-signed
admission path; commit-entry.yaml's counterpart to
`scripts/sign_statement.py`).

This is the step that answers "did the claimed author identity actually
sign THIS bundle?" — cert SAN, OIDC issuer, and Rekor transparency-log
inclusion are all verified cryptographically against Sigstore's trusted
root via the sigstore-python LIBRARY (`Verifier.verify_dsse`), the same
library + verification path milpa's own per-entry verifier uses. It does
NOT check whether the statement's subject matches what tianguis is about
to admit — that is `tianguis add-entry --entry-statement`'s job (Nim,
locally gate-able), by design: crypto proves "the claimed identity signed
THIS statement"; add-entry proves "this statement matches what we
actually admit" (content_hash it just recomputed + the purl it derives).
Both checks are required; neither substitutes for the other.

THE MODEL-3 IDENTITY FLOW (rfc-attestation-delivery.handoff.md — "VERIFIED
2026-07-11 … Model 3 confirmed"): under Model 3 the per-entry bundle this
script verifies is signed INSIDE THE AUTHOR'S OWN GitHub Actions job (the
publish composite action, `.github/actions/publish`) — its cert SAN is
`https://github.com/<author-org>/<repo>/.github/workflows/<wf>@<ref>`, a
genuinely per-author identity. This is DIFFERENT from — and no longer fed
by — the OCI cosign step's SAN in commit-entry.yaml, which is minted by the
SHARED `publish.yaml` *reusable* workflow and is therefore the same
constant identity for every author (see the handoff's "BOMBSHELL" finding).
The OCI cosign SAN stays useful for OCI-artifact provenance/Rekor only; it
must never again feed `signed_by`/namespace derivation.

Two verification modes, both against Sigstore's real trusted root — never
a local/offline check:

  1. KNOWN-SAN mode (`--certificate-identity=<SAN>` supplied): used when the
     target package ALREADY has a pinned `Package.authorizedSigner` in
     index.kdl (looked up by the caller via a namespace derived from the
     dispatch payload's untrusted `signed_by` hint — see commit-entry.yaml).
     `sigstore.verify.policy.Identity` does an atomic, single crypto-checked
     comparison: issuer AND exact SAN match, both verified against the same
     certificate in one `verify_dsse` call. This is the "cert SAN MUST equal
     the pinned signer" defense-in-depth check (S8 Layer 3's Nim
     `mokSignerMismatch` ratchet is the AUTHORITATIVE enforcement — this is
     belt-and-suspenders, catching a mismatch before the OCI pull + rest of
     the workflow even runs).
  2. ISSUER-ONLY / TOFU mode (`--certificate-identity` omitted or empty):
     used for a package with no pinned signer yet (brand new, or vendored-
     only so far). Verifies only the OIDC issuer via
     `sigstore.verify.policy.OIDCIssuer`, then EXTRACTS the cert's own SAN
     from the (now cryptographically verified) certificate and prints it —
     that extracted value becomes the authoritative `signed_by` add-entry
     records (first-use-pins-the-ratchet TOFU, enforced server-side by
     `mergeVendored`'s S8 Layer 3 check).

In both modes the extracted/confirmed SAN is printed to STDOUT (and ONLY
the SAN — nothing else) so the calling workflow can capture it with
`SAN=$(python3 verify_entry_bundle.py …)`; all human-readable / diagnostic
output goes to stderr.

Usage:
    # known-SAN mode (existing package, pinned signer)
    python3 scripts/verify_entry_bundle.py \\
        --bundle bundle.json \\
        --certificate-identity "$PINNED_SIGNER" \\
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \\
        --out entry-statement.json

    # issuer-only / TOFU mode (new package, no pin yet)
    python3 scripts/verify_entry_bundle.py \\
        --bundle bundle.json \\
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \\
        --out entry-statement.json

`--certificate-identity`, when supplied, MUST be the exact expected SAN —
`sigstore.verify.policy.Identity` does an EXACT string match (not a
prefix/regexp), unlike the `cosign verify --certificate-identity-regexp`
used for the OCI artifact.

NOT locally testable: talks to Sigstore's trusted-root distribution (TUF)
and validates a real Fulcio cert chain + Rekor transparency-log entry.
Exit codes: 0 success (statement payload written to --out; the verified/
extracted SAN printed to stdout); 3 bundle failed cryptographic
verification (bad signature, wrong SAN, wrong issuer, broken Rekor
inclusion proof, non-in-toto DSSE payload type, or an ambiguous/missing
identity SAN on the cert); 4 usage error (missing args, unreadable/empty
--bundle file).
"""
from __future__ import annotations

import argparse
import sys

from cryptography.x509 import (
    Certificate,
    OtherName,
    RFC822Name,
    SubjectAlternativeName,
    UniformResourceIdentifier,
)
from sigstore.errors import Error as SigstoreError
from sigstore.models import Bundle
from sigstore.verify import Verifier
from sigstore.verify.policy import _OTHERNAME_OID, Identity, OIDCIssuer

# The standard DSSE payload type for an in-toto Statement (in-toto
# attestation spec, predicate-agnostic). `buildEntryStatement` (Nim,
# attestation.nim) never sets this — it's a DSSE envelope concern set by
# whatever signs the statement (sign_statement.py's `Statement(contents=...)`
# wrapping, under the hood, sigstore-python's `sign_dsse`) — but verifying it
# here means a DSSE envelope that (for whatever reason) wraps something
# other than an in-toto statement is rejected before its payload ever
# reaches `tianguis add-entry --entry-statement`.
IN_TOTO_PAYLOAD_TYPE = "application/vnd.in-toto+json"


def extract_cert_identity(cert: Certificate) -> str:
    """Extract the single identity SAN from a verified Fulcio certificate.

    Mirrors `sigstore.verify.policy.Identity.verify`'s own SAN-set
    construction byte-for-byte (same OID, same three SAN types) — this is
    deliberately NOT a second reimplementation of "what counts as the
    identity"; it reuses the exact set sigstore's own policy checks
    membership against, so a cert that would satisfy
    `Identity(identity=X)` is guaranteed to extract to `X` here.

    Fulcio's GitHub Actions keyless certs carry exactly one identity SAN
    (a `UniformResourceIdentifier` naming the workflow ref). Raises
    `ValueError` (fail closed) if the cert carries zero or more than one
    distinct identity value — an ambiguous cert must never be silently
    resolved to "the first one we saw".
    """
    san_ext = cert.extensions.get_extension_for_class(SubjectAlternativeName).value
    all_sans: set[str] = set(san_ext.get_values_for_type(RFC822Name))
    all_sans.update(san_ext.get_values_for_type(UniformResourceIdentifier))
    all_sans.update(
        on.value.decode()
        for on in san_ext.get_values_for_type(OtherName)
        if on.type_id == _OTHERNAME_OID
    )
    if len(all_sans) != 1:
        raise ValueError(
            f"expected exactly one identity SAN on the signing certificate, "
            f"found {len(all_sans)}: {sorted(all_sans)!r}"
        )
    return next(iter(all_sans))


def verify_and_extract(
    bundle_bytes: bytes,
    certificate_oidc_issuer: str,
    certificate_identity: str = "",
) -> tuple[bytes, str]:
    """Verify `bundle_bytes` (a Sigstore Bundle JSON document) and return
    `(payload_bytes, signer_san)` on success.

    When `certificate_identity` is non-empty: KNOWN-SAN mode — the bundle
    MUST be signed by exactly that identity (`sigstore.verify.policy.
    Identity`, atomic issuer+SAN check). When empty: ISSUER-ONLY/TOFU mode
    — only the OIDC issuer is checked (`sigstore.verify.policy.OIDCIssuer`)
    and the signer's own SAN is extracted from the verified cert and
    returned.

    Raises `sigstore.errors.Error` (or a subclass, e.g. `VerificationError`)
    on any verification failure — bad signature, SAN mismatch, issuer
    mismatch, or a broken Rekor inclusion proof. Raises `ValueError` if the
    DSSE envelope's payload type is not the standard in-toto Statement type,
    or if the cert's identity SAN is missing/ambiguous.
    """
    bundle = Bundle.from_json(bundle_bytes)
    verifier = Verifier.production()
    policy = (
        Identity(identity=certificate_identity, issuer=certificate_oidc_issuer)
        if certificate_identity
        else OIDCIssuer(certificate_oidc_issuer)
    )
    payload_type, payload = verifier.verify_dsse(bundle, policy)
    if payload_type != IN_TOTO_PAYLOAD_TYPE:
        raise ValueError(
            f"DSSE payload type {payload_type!r} is not the expected "
            f"in-toto Statement type {IN_TOTO_PAYLOAD_TYPE!r}"
        )
    san = extract_cert_identity(bundle.signing_certificate)
    return payload, san


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bundle", required=True,
        help="path to the Sigstore Bundle JSON file (the author's per-entry attestation)",
    )
    parser.add_argument(
        "--certificate-identity", required=False, default="",
        help=(
            "the EXACT expected cert SAN (the package's pinned "
            "Package.authorizedSigner, when one exists). Omit for a "
            "brand-new package — issuer-only/TOFU mode then extracts and "
            "prints the signer's own SAN instead of comparing it to anything."
        ),
    )
    parser.add_argument(
        "--certificate-oidc-issuer", required=True,
        help="the expected OIDC issuer (https://token.actions.githubusercontent.com)",
    )
    parser.add_argument(
        "--out", required=True,
        help="path to write the verified in-toto statement JSON payload to",
    )
    args = parser.parse_args()

    try:
        with open(args.bundle, "rb") as f:
            bundle_bytes = f.read()
    except OSError as exc:
        print(f"verify_entry_bundle: cannot read --bundle {args.bundle}: {exc}", file=sys.stderr)
        return 4
    if not bundle_bytes.strip():
        print(f"verify_entry_bundle: --bundle {args.bundle} is empty", file=sys.stderr)
        return 4

    try:
        payload, san = verify_and_extract(
            bundle_bytes, args.certificate_oidc_issuer, args.certificate_identity,
        )
    except (SigstoreError, ValueError) as exc:
        print(f"verify_entry_bundle: bundle verification FAILED: {exc}", file=sys.stderr)
        return 3

    with open(args.out, "wb") as f:
        f.write(payload)
    mode = "known-SAN" if args.certificate_identity else "issuer-only/TOFU"
    print(f"verify_entry_bundle: verified ({mode}); statement written to {args.out}", file=sys.stderr)
    # ONLY the SAN goes to stdout — the calling workflow captures it via
    # `SAN=$(python3 verify_entry_bundle.py …)`.
    print(san)
    return 0


if __name__ == "__main__":
    sys.exit(main())
