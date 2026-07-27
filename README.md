# tianguis

The package registry for [milpa](https://github.com/coreyleavitt/milpa): a cryptographically-gated index of Nim packages.

## What it is

- **Content-addressed index** — every entry carries a hash of its source tree plus a Sigstore attestation. Canonical `index.kdl`, with a `index.json` projection published alongside.
- **Vendor-en-absentia** — a scheduled bot backfills the unadopted majority of `nim-lang/packages.json` into verifiable entries. Authors who adopt later override transparently.
- **Author publishing** — authors publish with `milpa publish` and a GitHub Actions composite action that keyless-cosign-signs the OCI artifact and mints a per-entry attestation under their own repository identity. A dispatch endpoint verifies that identity; a per-package signer ratchet pins the first signer (trust on first use).
- **No PR-curation gate** — cosign attestation is the sole gatekeeper on the publishing path.
- **Minimal infrastructure** — the index is served as static files over HTTPS; the only service is a stateless serverless dispatch function that gates publishes. No VPS, no database.

## Status

Implemented and live. This index is milpa's default registry.

## Documentation

See [`docs/rfc-registry.md`](docs/rfc-registry.md) and the other `docs/rfc-*.md` design records.

## License

TBD.

---

*A tianguis is the open-air market of the Mesoamerican milpa system.*
