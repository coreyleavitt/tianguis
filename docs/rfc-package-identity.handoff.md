# rfc-package-identity (#32) — handoff

- **Stage:** 1 RFC + slicing — **DRAFT DONE, sliced (S1–S6).**   •   **Round:** —
- **Resume:** `/architect docs/rfc-package-identity.md round 1`  (then round 2)
- **RFC:** `docs/rfc-package-identity.md`   •   **Prereq for:** `docs/rfc-index-deps.md`
- **Issue:** #32 (P0). Milpa consequences = separate milpa RFC, sequenced after S1–S6.

## Slices (gate = green each)
- [ ] S1 — `(namespace,name)` key + pure `deriveNamespace(url)→host/org` + canonicalization; nimkdl pair distinct
- [ ] S2 — `docs/spec/index-format.md`: namespace populated + part of key
- [ ] S3 — kdl_io parse/encode populated namespace + tuple-keyed lookup; round-trip
- [ ] S4 — vendor bot stamps `(host/org,name)` from `upstream`; #32 collision → two entries
- [ ] S5 — vendor bot bare→qualified require resolution at ingest over packages.json
- [ ] S6 — migrate/re-emit live ~2613-pkg index; validate (no `namespace ""`; pairs); milpa parses

## Open forks (awaiting Corey)
- `host/org` canonicalization rules (case, `.git`, host aliases, SSH/HTTPS, redirects).
- Schema-version bump: one v2 with rfc-index-deps, or staged.
- Index records exposed Nim module name(s) per pkg for pre-fetch collision detection? (milpa-side).

## Key decisions (grill 2026-06-06)
- Identity = `(host/org, name)`, namespace = attested publisher identity derived from provenance.
- **No bare-name ownership** (Go-style); bare→qualified only at vendor ingest over packages.json; one-way interop (milpa consumes legacy, no reverse shim); bare world closed over packages.json.
- Milpa consumer contract (determined): namespace invisible to compiler/source; same-module collision → permanent detect-and-error; merge NamedDep+UrlDep into one qualified-reference kind; trust = integrity-anchor axis; anchorless fetch → opt-in + lockfile `unverified` (b+c); local = possession (gate-exempt), tarball = sha256 (both distinct).

## Review ledger (stage 4)
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
| —  | —   | (not yet reviewed) | — | — |
