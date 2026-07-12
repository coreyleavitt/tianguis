# attestation-delivery (tianguis#42 / milpa P4) — handoff

- **CI-VALIDATED 2026-07-12:** merged to `main` (`e7d510c`, rebased over 10 daily
  vendor commits, clean). Backfill dry-run (run 29182522590) GREEN: minted 3 real
  Sigstore bundles under GH-Actions OIDC + verified them against Sigstore prod
  root + Rekor via verify_entry_bundle.py; apply/parity/commit/cosign all SKIPPED
  (dry_run guards → zero production mutation). `parity` + `pages` + `dispatch-deploy`
  (Cloud Function redeploy w/ entry_bundle_b64) all GREEN on the main push. First
  actionlint fix: empty `${{ }}` in a run-block comment invalidated commit-entry.yaml
  (`6fd5b3b`). Artifact `attestation-bundles` = 3 real P4 fixtures. **The keyless
  seam that could never be locally gated is now proven end-to-end.**
- **FULL BACKFILL COMPLETE 2026-07-12** (`ed1691d`→`36a8541`): ran `dry_run=false`
  in cap=500 batches (5 validation + 6 bulk); **2898/2898 eligible milpa-vendored
  entries now carry a real Rekor-anchored bundle** (index accounting: 2899
  content_hash − 2898 pins − 1 author-signed = 0 pinless-non-author). Found+fixed
  a latent commit-guard bug (`f5f209c`): a no-op pass churns milpa.lock via
  `milpa fetch` so `git status --porcelain` mis-fires → empty `git commit` fails;
  now stages index/alerts/attestation then gates on `git diff --cached --quiet`.
  Fixed in BOTH backfill-attestation.yaml AND vendor.yaml (same latent bug).
- **EPOCH ARMED 2026-07-12** (`286e47f` command + `bab3661` arm): built
  `tianguis set-attestation-epoch` (set-once guard + safety guard reusing
  merge.nim's S5 `attestationGateRejects` via a synthetic mergeVendored probe;
  15 tests, 415 suite assertions green) and set root `attestation-epoch
  "2026-07-12T00:00:00Z"` on production `main`. Safety guard confirmed 0 would-be
  violations (all 2898 eligible backfilled first). Parity OK. **The S5 strict gate
  is now LIVE** — every entry published on/after today must carry attestation+pin;
  the daily vendor mint loop (S7b) now runs live (fails closed if signing is down).
- **REMAINING = operational (Corey's call, NOT code):** real author-signed E2E
  needs a real author repo publishing via the composite action — the crypto seam
  is proven (same verify path), but the full author→dispatch→commit-entry flow is
  unexercised end-to-end. Everything else (delivery, backfill, epoch) is DONE + LIVE.
- **Stage:** TDD (rfc-flow stage 3) COMPLETE — ALL SLICES S1–S9 LANDED (incl.
  S7c shared core + the Model-3 author-signed trust stack: L1 composite action /
  L2 per-author namespace SSOT / L3 signer ratchet + A/B/C). Full nim suite:
  **28/28 green** on the final committed tree (`39e9123`). `closes #42` in the S9
  commit. **NOTHING PUSHED.**
- **Resume / next:** push to a branch + drive S7b/S8/S9 workflows through real CI
  (the sign_dsse keyless seam + dispatch are CI-only — see "CI boundary" below).
  Then S9 backfill run produces milpa's P4 real-crypto fixtures.
- **Commits (this grind):** S7c `d848b58`/`58fce52`, S7b `9b9df3e`, S8 A+C
  `97b97f7`, S8 L3 `0092ebe`, S8 L2+B/D `e8c363b`, S9 `39e9123` (+ docs
  `e2f71fa`/`ff29a4c`/`0746c47`).
- **CI-only (cannot local-gate):** the `sign_dsse` keyless signing in
  vendor.yaml / commit-entry.yaml / backfill-attestation.yaml (needs GH-Actions
  OIDC), verify_entry_bundle.py against a real Fulcio+Rekor bundle, the composite
  action end-to-end, and byte-for-byte SAN↔namespace agreement. A real CI run
  must confirm all of these.
- **Bugs caught + root-fixed during grind:** S7b stale-pin re-candidating every
  daily pass; S9 `vendor --bundle-pins` silently dropping the minted pin on
  already-committed entries (→ dedicated `applyBackfillPins`).
- **Repo:** this is the **tianguis** repo (Nim registry). Cross-references the
  **milpa** repo at `/home/corey/projects/milpa` (the consumer/resolver).

## What this is

The tianguis-side implementation of per-entry attestation **delivery** —
milpa's P4 (RFC `docs/rfc-per-entry-attestation.md` in the milpa repo, §1 +
§2 + §7; tracking milpa#184). Issue **coreyleavitt/tianguis#42**. Makes
milpa's `entry-trust "strict"` actually functional: every attested entry gets
a real Sigstore bundle, content-addressed and pinned from the (Layer-1-signed)
index, so milpa can verify per-entry author/vendor attribution offline.

## The milpa-side contract (frozen — do NOT redesign; these are what milpa parses)

- **Per-entry bundle pin (RFC §2):** each attested version node gains a 4th
  attestation sibling `bundle sha256="<64-hex>"` — sha256 of the bundle BYTES.
  milpa parses it in `registry.py:_parse_version_node` / `registry.rs`.
- **Content-addressed tree (§7):** milpa fetches
  `<index_base_url>/attestation/<sha256_hex>.bundle` (flat file, NOT a
  directory-per-hash; issue #42 deliverable 1). Immutable, cache-forever.
  Same URL-derivation as milpa's `dep-decl/`. NOTE: tianguis has **no existing
  `dep-decl/` tree** — this serving path is new infra (see Findings).
- **Subject binding (§1, NORMATIVE):** the per-entry DSSE in-toto statement's
  `subject[0]` MUST bind BOTH: `digest.sha256` = hex of the entry's
  `content_hash` (scheme-agnostic extract from `dag-sha256:<hex>`, never a
  hardcoded `sha256:` strip) AND `name` = `pkg:tianguis/<namespace>/<name>@<version>`.
  Digest binding stops stale-bundle reuse; name binding stops cross-package
  replay (content_hash is name-independent). milpa checks both **before**
  crypto (stages 3/4 → TNG-ENTRY-DIGEST-MISMATCH / TNG-ENTRY-SUBJECT-MISMATCH).
- **Expected signer by kind (milpa gate stage 6):** `author-signed` → the
  author's Fulcio/OIDC identity (recorded as `signed_by`); `milpa-vendored` →
  the vendor-bot workflow identity (the same one Layer 1 already trusts).
- **Root epoch (§ issue #42 deliverable 5):** root-level `attestation-epoch`
  field in `index.kdl`. milpa already parses it (`index_ratchet_seam.py:
  _raw_attestation_epoch`) and #185's ratchet freezes it (set-once →
  TNG-INDEX-ROOT-MUTATED) so it can't be backdated/stripped. Every entry with
  `published_at >= epoch` MUST carry attestation + pin.
- **Rekor:** tianguis already emits `rekor { uuid; log_index; integrated_time }`
  per author-signed entry. The bundle must carry the real inclusion proof
  (milpa stage 7 verifies it).

## Findings from exploration (2026-07-11) — read before starting

1. **No `dep-decl/` sidecar precedent in tianguis.** Issue #42 says "sibling of
   `dep-decl/`" but that tree lives in milpa's fetcher concept, not tianguis.
   `site/scripts/build.py` copies only `index.kdl`/`index.json` into
   `site/_build/`. The `attestation/` tree needs a NEW serve step there (S6) or
   GH Pages serves nothing.
2. **The mint step exists but attests the WRONG subject.** `commit-entry.yaml`
   already runs `cosign attest-blob --bundle commit-attest.bundle` and discards
   it — but that bundle attests tianguis's own commit-decision *custom predicate*
   (name/version/oci_ref/…), NOT the §1 in-toto subject (content_hash + pkg
   name). We cannot "persist what's minted"; the attested statement must change
   to the §1 statement (S3).
3. **author-signed digest mismatch (the hard part).** Authors today cosign-sign
   their **OCI artifact** (bound to the OCI manifest digest); milpa's subject
   binds the **`content_hash`** (dag-sha256 of source tree) — different digests.
   The bot re-attesting would make it bot-signed (defeats the "bot can't
   fabricate author-signed" property). **Resolution (approved mechanism):** the
   author must produce a cosign attestation over the §1 in-toto statement (S3),
   carried through the `repository_dispatch` protocol. This is the S8 redesign.

## Codebase map (tianguis)

- **Model:** `src/tianguis/model.nim` — `Version` (contentHash, requires,
  attestation, signedBy, publishedAt, provenances, rekor: Option[RekorRef],
  partiallyResolved), `Package`, `Index` (schemaVersion, packages), `RekorRef`.
  `canonicalize`, `==` overloads (MUST update `==` for any new field).
- **KDL emit/parse:** `src/tianguis/kdl_io.nim` — `formatVersion` (emits
  content_hash, requires, provenance*, attestation, signed_by, published_at,
  rekor?, partially_resolved?), `parseVersion`, strict allowlists
  `TopLevelNodes` / `PackageChildren` / `VersionChildren` / `RekorChildren`
  (`test_strict_schema.nim` gates these). `formatKdl`/`parseKdl` (root:
  schema_version + package). NO dep_decl, NO yanked, NO bundle pin today.
- **JSON projection:** `src/tianguis/json_io.nim` — MUST mirror any KDL change
  (parity invariant `tianguis project --check`, CI `parity.yaml`).
- **CLI:** `src/tianguis/cli.nim` — cmdProject/cmdVendor/cmdReindex.
  Add-entry: `src/tianguis/vendor/addentry.nim` (`cmdAddEntry`, `AddEntryArgs`,
  injectable `AddEntryDriver`). Merge outcomes: `src/tianguis/vendor/merge.nim`
  (`MergeOutcomeKind`: mokAdded/mokIdempotent/mokIdentityDrift/mokCollision/
  mokContentDrift/mokRebaselined — add a new kind for missing-attestation).
  publishedAt set in addentry.nim (~135) + orchestrate.nim (~118).
- **Publish workflow:** `.github/workflows/commit-entry.yaml` (author-signed,
  triggered by `repository_dispatch: tianguis-publish` from the Cloud Function
  in `dispatch/`). Verifies author cosign over OCI, extracts rekor, calls
  `tianguis add-entry`, mints+discards the commit-decision bundle.
- **Serve:** `site/scripts/build.py` → `site/_build/`; `.github/workflows/pages.yaml`.
- **Tests:** plain `for f in tests/test_*.nim; do nim c -r --hints:off "$f"; done`
  (no framework; std unittest inside each). Mirror templates:
  `test_kdl_roundtrip.nim` / `test_json_roundtrip.nim` (roundtrip+canonical),
  `test_strict_schema.nim` (allowlist rejection), `test_cmd_add_entry.nim`
  (CLI via injected fake driver + `withTempProject`), `test_vendor_merge.nim`
  (MergeOutcomeKind). Deps `_deps/nkdl` + `_deps/nimcrypto` must be present
  (`milpa fetch` first). No container recipe; CI on ubuntu-latest.
- **Test gate (VERIFIED 2026-07-11).** No nim on host; deps present in `_deps/`
  (CAS lives repo-relative at `.milpa/cas/`). Single test:
  ```
  podman run --rm -v /home/corey/projects/tianguis:/work:Z \
    -v "$HOME/.cache/milpa":/root/.cache/milpa:Z -w /work \
    docker.io/nimlang/nim:2.2.0 bash -c \
    "nim c -r --hints:off --path:src --path:_deps/nkdl/src --path:_deps/nimcrypto tests/test_<name>.nim"
  ```
  Full suite: same, with `bash -c 'set -e; for f in tests/test_*.nim; do nim c -r
  --hints:off --path:src --path:_deps/nkdl/src --path:_deps/nimcrypto "$f"; done'`.
  Image `docker.io/nimlang/nim:2.2.0` is already pulled/cached. Python (build.py,
  S6) tests run on host via uv/pytest if a test harness exists, else a plain
  script check.

## Slices (vertical; TDD-clean first, workflow/infra after)

- [x] **S1 (`6d5ba94`) — per-entry `bundle sha256` pin field.** `model.Version` gains the
      pin (shape: a typed `bundlePin: Option[string]`, or fold into an
      EntryAttestation-shaped record mirroring milpa §2 — decide at S1, lean
      Option[string] since the other 3 siblings are already separate fields).
      Emit in `formatVersion` as `bundle sha256="<hex>"`; parse; add to
      `VersionChildren` allowlist + a `BundleChildren`/arg check; update `==`;
      mirror in json_io. Tests: roundtrip (kdl+json) + strict-schema.
- [x] **S2 (`54f8baf`) — root `attestation-epoch` field.** `Index` model gains it; emit/parse
      at root; add to `TopLevelNodes`; update `==`; mirror json. Roundtrip +
      strict-schema tests. (Must match milpa's parsed name exactly.)
- [x] **S3 (`a9e4343`) — §1 in-toto statement builder.** Pure Nim proc:
      `buildEntryStatement(ns, name, version, contentHash) -> string` (canonical
      in-toto/DSSE predicate JSON) with `subject[0].digest.sha256` =
      scheme-agnostic hex of contentHash, `subject[0].name` =
      `pkg:tianguis/<ns>/<name>@<version>`. Unit tests vs RFC §1 (incl.
      dag-sha256 scheme strip, name format, purl escaping). This is the bytes
      the author/bot signs.
- [x] **S4 — content-addressed bundle store.** Nim proc: given bundle bytes →
      sha256 → write `attestation/<hex>.bundle` → return pin; idempotent.
      Tempdir tests (write, idempotent re-write, returned pin == sha256).
- [x] **S5 (this commit) — publish-time epoch gate.** In add-entry / vendor-merge: if
      `published_at >= attestation-epoch` and (no attestation OR no pin) →
      reject with a new `MergeOutcomeKind` (e.g. `mokMissingAttestation`).
      Tests via the merge-outcome pattern (before-epoch ok; after-epoch w/o
      pin rejected; after-epoch w/ pin ok).
- [x] **S6 (`979af13`) — serve the tree.** `site/scripts/build.py` copies `attestation/`
      into `site/_build/`. Python test (tree copied, flat layout preserved).
- [x] **S7a (pending-commit) — bundle-pin admission wiring (Nim core of S7).**
      `add-entry --bundle-pin=<64hex>` + `buildVendoredEntry(bundlePin=...)`
      thread a minted pin into `Version.bundlePin`; validated 64-hex; ties to
      S5 (pin present ⇒ post-epoch accept). Full nim suite green.
- [ ] **S7c (shared core, LOCALLY GATE-ABLE) — `tianguis attest-statement` CLI +
      Python sign seam.** Single-source the S3 statement: a CLI subcommand
      `tianguis attest-statement --ns --name --version --content-hash` emits the
      exact `buildEntryStatement` JSON (TDD via nim gate). `scripts/sign_statement.py`
      reads statement JSON on stdin, calls sigstore-python `sign_dsse` under
      ambient OIDC, writes BUNDLE_0_3 to stdout; `scripts/mint_bundle.py` wires
      emit→sign→writeBundle→pin. Only the `sign_dsse` call is CI-only; arg
      handling + statement passthrough smoke-testable. **Decision: composite
      action for author UX (Corey approved 2026-07-11); verify S7b/S8/S9 on CI.**
- [ ] **S7b — vendored minting WORKFLOW (CI-verified, NOT local-gate-able).**
      In the vendor workflow / commit path: build the S3 statement, run
      `cosign attest-blob` keyless (bot identity) over it, persist the bundle
      via S4 `writeBundle` → pin, pass pin to `buildVendoredEntry`/`--bundle-pin`.
      **Cannot be gated by the nim container — needs GH Actions OIDC.** Verify
      by running the workflow in CI or careful manual review, not the local gate.
- [ ] **S7 (orig, superseded by S7a+S7b).** vendor path: build S3
      statement → cosign attest-blob keyless (bot identity) → bundle → S4 pin →
      add-entry with pin. Test the Nim cores (S3/S4) + wiring via the add-entry
      fake-driver; workflow YAML is integration-tested manually / via backfill.
- [ ] **S8 — author-signed protocol redesign (CI + Cloud Function + DESIGN DECISION).** Author produces
      a cosign attestation over the S3 statement; extend `repository_dispatch`
      payload to carry the author's bundle; `commit-entry.yaml` verifies the
      author's cert SAN over the §1 subject (content_hash + name, not just OCI),
      Rekor inclusion, persists bundle (S4) + pin. Touches `dispatch/` Cloud
      Function + author-side tooling. **Carries an open design sub-decision**
      (exact author→dispatch→workflow bundle handoff; whether author runs cosign
      locally over S3 or via a helper) — resolve at S8 or escalate.
- [ ] **S9 — backfill.** Batched `workflow_dispatch` minting vendored bundles for
      existing entries. Doubles as milpa's P4 real-crypto fixture source
      (mirrors milpa `generate-attestation-fixture.yaml`).

## RESOLVED: bundle-minting recipe (2026-07-11, verified vs milpa's real verifier)

Gating unknown for S7b/S8 answered — **no milpa spec change needed.**

- milpa's per-entry verifier does a PLAIN OPAQUE STRING compare of
  `subject[0].digest.sha256` vs the entry content_hash hex, literal `"sha256"`
  key, NEVER recomputes (Python `entry_trust.py:288`, Rust `entry_trust.rs:311`).
  `predicateType`/`_type` ignored. So the minted statement just needs that hex.
- cosign CLI / `sigstore attest` CANNOT set an arbitrary subject digest (they
  auto-derive it from a file's real sha256). Unusable.
- **Mint with the sigstore-python LIBRARY** (same lib ≥3.0 milpa verifies with;
  installed 4.3.0) — `Signer.sign_dsse(StatementBuilder(subjects=[Subject(
  name="pkg:tianguis/<ns>/<name>@<version>", digest={"sha256":"<dag-sha256-hex>"})],
  predicate_type=..., predicate={...}).build())` under a `SigningContext.
  from_trust_config(ClientTrustConfig.production())` with ambient GH-Actions OIDC
  (`detect_credential()`). `sign_dsse` emits a BUNDLE_0_3 that
  `SigstoreEntryVerifier` loads/verifies as-is. S3's attestation.nim produces the
  same statement JSON; the workflow can rebuild it in python or pass fields in.
- Digest-key overload stays as RFC §1 wrote it: sigstore-python's `Subject`
  pydantic model REQUIRES a standard `sha*` key (a `dag-sha256` key raises
  ValidationError) but leaves the VALUE unconstrained — so the "honest" rename
  would be strictly worse. **Spec change: NO.**
- **HARD CONSTRAINT — signing must run in GitHub Actions.** milpa's `Identity`
  policy hardcodes issuer `https://token.actions.githubusercontent.com`
  (`entry_trust.py:347`); both the bot (S7b) and the author (S8) sign via a
  GH-Actions workflow (ambient OIDC → workflow SAN = `signed_by`). Local OAuth
  signing → different issuer → `SignerMismatch`. This is the irreducibly
  CI-bound seam.
- P3b (Rust real-crypto) unaffected: the BUNDLE_0_3 + `sha256`-key subject is
  exactly what both impls' pre-crypto stage expects.

## CI boundary + open decision (reached 2026-07-11)

S1–S7a (schema, epoch gate, in-toto statement, bundle store, serve, pin
admission) are all landed and **locally gate-green** via the nim container.
S7b/S8/S9 change character — they are GitHub Actions / cosign-keyless /
cross-service work that the local gate **cannot verify** (keyless signing
needs Actions OIDC; the dispatch Cloud Function is a separate deploy). They
must be verified in CI (push + watch Actions) or by careful review.

**S8 open design sub-decision (needs Corey):** how the author's
content_hash-bound attestation reaches tianguis.

**SHARPENED 2026-07-11 by the minting resolution — the "author runs cosign
locally" shape is now RULED OUT.** milpa hardcodes issuer
`https://token.actions.githubusercontent.com` (entry_trust.py:347), so a bundle
minted from an author's *local* OAuth session (issuer github.com / google /
etc.) fails `SignerMismatch` regardless of SAN. Therefore the author's
attestation MUST be produced inside the **author's own GitHub Actions workflow**
via ambient OIDC — the workflow's SAN becomes `signed_by`, and milpa's stage-6
`author-signed` gate trusts that identity. Local-cosign is not merely worse
ergonomics; it's non-verifiable by milpa. This is a forced consequence, not a
fork.

**Resulting recommended shape (the actual open piece):** the author's release
workflow (a) computes `content_hash` (via `milpa hash` over the source tree),
(b) builds the S3 in-toto statement, (c) signs it with sigstore-python
`sign_dsse` under ambient Actions OIDC, (d) sends the resulting BUNDLE_0_3
bytes (base64) in the `repository_dispatch: tianguis-publish` payload alongside
today's fields. `commit-entry.yaml` then RECOMPUTES content_hash from the
fetched source, fully verifies the bundle (author SAN + Rekor inclusion +
§1 subject binding: content_hash digest AND pkg name, not just the OCI digest
it checks today), persists via S4, records the pin. The genuinely
under-determined bit left for Corey: **author-side UX** — do we ship a reusable
composite GH Action (`coreyleavitt/tianguis-publish-action`) the author drops
into their release workflow, or hand-rolled YAML in a docs template? (Lean:
reusable composite action — one pinned ref, no copy-paste drift.) This changes
the dispatch payload schema + `dispatch/` Cloud Function passthrough + author
onboarding docs — the piece Corey chose "full scope" for.

## Open forks awaiting Corey

### ⚠️ S8 IDENTITY-MODEL FORK (BLOCKING — held uncommitted 2026-07-11)

**Discovery during S8 build:** the existing OCI-cosign path (`publish.yaml`) is a
`workflow_call` **reusable workflow** that *deliberately* self-derives the cosign
signer from its own `job_workflow_ref` (#30, lines 117–148). Fulcio therefore
stamps EVERY author's OCI signature — and today's `signed_by` in index.kdl — with
the SHARED identity `coreyleavitt/tianguis/.github/workflows/publish.yaml@<ref>`,
NOT the individual author. "author-signed" today really means "produced through
the official tianguis publish pipeline."

This breaks the composite-action choice: a composite action runs in the AUTHOR's
own job → SAN = `<author>/<repo>/.github/workflows/<x>.yaml@<ref>`, which ≠ the
shared publish.yaml SAN that commit-entry.yaml's S8 crypto step matches against
(`steps.cosign.outputs.san`). **As-built, S8's part D (composite action) produces
a bundle that S8's part B (SAN-match verify) rejects.** Root cause: my brief
assumed "OCI cosign and per-entry bundle share a SAN" — false under reusable-wf.

**The fork (registry-wide `signed_by` semantics — needs Corey):**
- **Model 1 — shared-pipeline identity (consistent w/ today, smaller).** Sign the
  per-entry bundle INSIDE `publish.yaml` (or a reusable wf) so its SAN == the OCI
  SAN. `signed_by` stays the publish-workflow ref. S8 part B works unchanged;
  part D drops the composite action. "author-signed" = "official-pipeline-signed"
  (weak per-author claim; near-indistinguishable from milpa-vendored in trust).
- **Model 2 — true per-author identity (faithful to milpa §1, bigger).** Authors
  sign in their OWN repos (composite action, as built). `signed_by` becomes the
  author's repo identity. Requires: (a) decoupling per-entry SAN verification from
  the OCI SAN, and (b) a trust chain establishing that the author's SAN is
  authorized for the namespace (today that authorization rides the dispatch OIDC
  cross-check + namespace-from-OCI-SAN derivation — would need rework).
- **Model 3 — decoupled `signed_by` (middle).** `signed_by` = author's per-entry
  bundle SAN (composite action); OCI stays publish-wf-signed; commit-entry verifies
  the per-entry bundle against the author identity carried in the dispatch payload,
  authorized via the existing dispatch OIDC verify. Smaller than Model 2, keeps
  per-author attribution, but splits "who signed the artifact" from "who signed the
  attestation."

**Recommendation:** genuinely goal-underdetermined — it turns on whether milpa's
"author-signed" tier is meant to be *cryptographic per-author attribution* (→ M2/M3)
or *proof-of-official-pipeline* (→ M1). If the former (which §1's "author's
Fulcio/OIDC identity" wording implies), **lean Model 3**: keeps the composite
action Corey approved, delivers real per-author SANs, and reuses the existing
dispatch-OIDC authorization instead of inventing a new namespace-authz chain.
Model 1 is the low-risk fallback if per-author crypto isn't the actual goal.

### VERIFIED 2026-07-11 (two read-only investigations) — Model 3 confirmed, scope widened

**milpa side (ratchet + verifier):**
- #185 ratchet's `attestation` field is `ATTESTATION_MONOTONE` (`ratchet.py:284`,
  `_dominates_attestation` 330-347): per-`(ns,name,version)` signer IS frozen —
  same version can't flip signer (`MONOTONE_REATTRIBUTED`), downgrade
  author→vendored, or strip. But scope is strictly per-exact-version. **NO
  per-PACKAGE signer continuity** (v N vs N+1). The `(ns,name)→allowed-signer`
  "owner registry" is explicitly milpa **Part 3, unbuilt** (`rfc-per-entry-
  attestation.md` OQ3, lines 64-67/568-581).
- Verifier (`entry_trust.py:489-493`): author-signed expected signer = the
  entry's OWN `signed_by` from the index; milpa-vendored = config
  `expected_vendor_signer` (not per-entry). Issuer hardcoded `:347`. milpa does
  NO independent authz — it trusts the Layer-1-signed + ratchet-protected index's
  `signed_by`. **So milpa's authz root = index integrity.** (Confirms the ratchet
  is the right place for authz.)

**tianguis side (THE BOMBSHELL):**
- Author-signed OCI path is **effectively SINGLE-NAMESPACE**. `publish.yaml` is a
  reusable wf → cosign SAN is the CONSTANT `github.com/coreyleavitt/tianguis/
  .github/workflows/publish.yaml@<ref>` for EVERY author. `deriveNamespace`
  (`addentry.nim:178`, `namespace.nim:224-286`) parses that URL → org=`coreyleavitt`.
  **Every author-signed publish lands in namespace `coreyleavitt`, whoever they are.**
- `rfc-package-identity.md:203-215` intended deriving namespace from the OIDC
  `repository_owner` claim (caller's own org) — `grep repository_owner` = ZERO
  hits. **Never implemented.**
- **NO per-package signer-continuity check** anywhere. `mokIdentityDrift`
  (`merge.nim:231-258`) compares only namespace (constant → useless);
  `mokCollision` is structurally inert for OCI-only entries (no pkGit provenance
  to compare). A different author CAN publish v N+1 under an existing
  `(ns,name)` → merge just appends (`mokAdded`). **No takeover protection.**
- `Package` (`model.nim:72-76`) = {name, namespace, upstream, versions}. No
  package-level signer field. `Version.signedBy` is per-version only.
- Dispatch (`handler.go`) = pure authenticated relay; `identityMatchesRepoURL`
  checks token-repo vs caller's SELF-declared RepoURL, never the package name.
  Zero package-scoped authz. `signed_by`/`entry_bundle_b64` pure passthrough.

**Consequence:** the composite action (Model 3 part D) is not stylistic — it is
the ONLY thing that produces a real per-author SAN (runs in the caller's job →
SAN = author's own repo), fixing the single-namespace collapse. But a signer
ratchet on today's plumbing would pin the same constant `coreyleavitt` for every
package. So **best-in-class Model 3 is a 3-layer stack, not just B/D:**
1. composite action → real per-author SAN (S8 part D, BUILT).
2. `add-entry` derives namespace from the AUTHOR bundle's SAN (not the shared
   OCI cosign SAN) → genuine per-author namespaces. (small change to what feeds
   `deriveNamespace`.)
3. per-package **signer ratchet**: `Package.authorizedSigner: Option[string]`,
   pinned at first author-signed ingest, checked in `mergeVendored` as a new
   priority tier (reject v N+1 whose `signedBy` ≠ pinned signer). = milpa's
   deferred Part-3 owner registry, realized at the tianguis admission boundary.
   milpa's OWN independent owner-registry enforcement (not trusting the bot)
   stays a separate milpa Part-3 slice.

This is PyPI-trusted-publishing + TOFU-ratchet — the real best-in-class shape.
**Scope decision for Corey:** build the full 3-layer stack now (author-signed
becomes MEANINGFUL) vs ship delivery mechanics + honest labeling and sequence
the ratchet as Part 3. Lean: full stack now — a per-author tier that collapses
every author to one identity is not worth shipping.

**S8 build status:** part A (Nim `add-entry --entry-statement` subject-binding,
exit 5) + part C (Go `entry_bundle_b64` passthrough) are model-INDEPENDENT and
gate-green. Parts B (SAN-verify target) + D (composite vs reusable signer) are
model-dependent and HELD. Nothing committed. Also surfaced: `milpa publish`
subcommand does not exist yet (publish.yaml invokes it — aspirational); milpa-ref
pin duplicated in composite action; normalizeVersion re-implemented in action bash.

## Cross-repo coordination

- After S1/S2 land, milpa's P3b can wire real crypto against the S9 backfill
  bundles as fixtures (milpa `docs/rfc-per-entry-attestation.handoff.md`; the
  Rust sigstore-rs verify-against-known-digest vendored-patch decision, #183).
- Do NOT run git in delegated subagents (milpa standing rule
  [[feedback_delegated_agents_no_git]] applies here too — shared tree).
- Commit style: check tianguis's own convention (it has its own git history);
  do not assume milpa's.
