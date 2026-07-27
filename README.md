# tianguis

The package registry for [milpa](https://github.com/coreyleavitt/milpa).

A tianguis is the open-air market where Mesoamerican milpa growers
brought their corn, beans, and squash to trade. This is where milpa
users find Nim packages.

## What this is

- An automated, cryptographically-gated package index. No PR-curation
  step on the publishing path; cosign attestation is the sole
  gatekeeper.
- Day-one ecosystem coverage via vendor-en-absentia: a scheduled bot
  walks `nim-lang/packages.json` and writes verifiable content-hashed
  entries for the unadopted majority of packages. Authors who adopt
  later override transparently.
- Author publishing: authors publish with `milpa publish` plus a GitHub
  Actions composite action that keyless-cosign-signs the OCI artifact and
  mints a per-entry Sigstore attestation under the author's *own* repo
  identity. A stateless dispatch endpoint verifies that OIDC identity, and
  a per-package signer ratchet (TOFU — trust on first use) pins the first
  signer so a later version can't be published by a different identity.
- Format: KDL canonical (`index.kdl`), JSON projection auto-published
  alongside (`index.json`).
- Hosting: the index is served as static files over HTTPS; the only moving
  part is a stateless serverless dispatch function that gates author
  publishes. No VPS, no database.

## Status

Implemented and live. The vendor-en-absentia bot has backfilled the
unadopted majority of `nim-lang/packages.json` into `index.kdl` — each entry
carrying a content-addressed identity plus a Sigstore attestation — and a
daily cron keeps it fresh. The author-signed publishing path works end to
end (`milpa publish` → composite action → dispatch → commit-entry
admission → append-only index). This index is milpa's default registry. See
[docs/rfc-registry.md](docs/rfc-registry.md) and the other `docs/rfc-*.md`
files for the design record.

## License

TBD.
