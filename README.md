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
- Format: KDL canonical (`index.kdl`), JSON projection auto-published
  alongside (`index.json`).
- Hosting: GitHub Pages. No backend service. No VPS. No database.

## Status

Design phase. See [docs/rfc-registry.md](docs/rfc-registry.md) for the
full RFC. Implementation tracked under the
[registry — tianguis](https://github.com/coreyleavitt/tianguis/milestones)
milestone.

## License

TBD.
