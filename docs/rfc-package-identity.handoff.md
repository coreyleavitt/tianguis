# rfc-package-identity (#32) — handoff

- **Stage:** 3 implementation — **S1–S5 DONE + verified green (18 test files); S6
  DEFERRED by Corey (2026-06-06).** S4 split into 4a(core)+4b(`tianguis show`).
- **S6 deferred because:** vendoring CI already failing (don't chase — big rewrite
  coming, [[feedback_commit_cadence_ci_defer]]); S6 also needs the spec fix (see ⛔
  blocker below) + the milpa gate, which is itself HELD until the milpa resolver-swap
  effort commits (Corey: avoid entangling two efforts in milpa's tree).
- **Resume (when ready):** (1) milpa resolver-swap lands & commits → (2) milpa
  `parse_index` tuple-key gate + two-nimkdl fixture test → (3) get approval for the
  corrected-S6 spec edit (derive-all + per-version regroup) → (4) execute S6 migration.
- **UNCOMMITTED:** all S1–S5 code + RFC/handoff edits are on disk, not committed
  (awaiting Corey's go-ahead). Issues filed this session: #38.
- **RFC:** `docs/rfc-package-identity.md`   •   **Prereq for:** `docs/rfc-index-deps.md`
- **Issue:** #32 (P0). Milpa consequences = separate milpa RFC, sequenced after S1–S6
  (except milpa `parse_index` tuple-key update, pulled forward as the S6 gate).
- **Open forks:** none. (Schema-version resolved r1; all r2 findings were clear-best.)

## Test command (verified 2026-06-06)
nim runs in a container (no host toolchain). Full suite:
```
cd /home/corey/projects/tianguis && podman run --rm --pull=never -v "$PWD":/work:Z \
  -w /work ghcr.io/coreyleavitt/nim:2.2.10 bash -c \
  'for f in tests/test_*.nim; do nim c -r --hints:off "$f" || break; done'
```
(`_deps/` already populated by a prior `milpa fetch`; nim.cfg uses relative `--path:`.)

## Slices (gate = green each) — updated by round 2
- [x] S1 — `deriveNamespace -> Result[ForgeRef, DerivationError]` (structured
      parse→normalize→serialize: forges + per-forge case + SSH `git@` residue +
      percent-decode + gitlab depth>2 fail + no-org fail) **+ promote tuple into model:
      `mergeVendored` lookup, `canonicalize` sort, `DriftAlert` qualified, +
      immutability-guard mechanism (`checkIdentityStable`, distinct drift)**.
      DONE — `src/tianguis/namespace.nim` (new), merge.nim + model.nim updated;
      `tests/test_namespace.nim` (new, 24) + 4 new merge tests; 14/14 files green.
      Guard wiring into packages.json re-ingest correlation = S4.
- [x] S2 — spec: namespace=host/org + key + structured canon (ForgeRef + topology
      table + case policy) + ordering + gloss + transitional requires note +
      `spec/fixtures/derive-namespace.json` (40 cases). DONE — index-format.md
      updated; corpus consumed by Nim `tests/test_namespace_corpus.nim`. **Python
      (milpa) consumption of the SAME json = cross-repo gate, deferred to milpa RFC
      (like the S6 parse_index gate) — corpus is impl-agnostic.**
- [x] S3 — kdl_io host/org round-trip + two same-`name` survive. DONE — kdl_io was
      already pure serialization (no bare-name lookup; `/`+`.` pass KDL quoting
      verbatim); 3 regression tests added to test_kdl_roundtrip.nim (host/org
      round-trip, #32 pair survives parse→emit→parse as 2 entries, canonical order
      stable). 15/15 files green.
- [x] S4 — DONE. `buildVendoredEntry → Result` (hard-reject underivable provenance);
      `mergeVendored` intra-org collision (different repo, same (ns,name) → reject new
      / preserve existing / `MergeOutcome.collision` + `IDX-INTRAORG-COLLISION` in
      alerts); `deriveRepo`/`RepoRef` factored into namespace.nim (single parser
      `parseToRepoRef`); denylist tuple-keyed (`Denylist.entries: HashSet[(ns,name)]`,
      `parseDenylist` reads `namespace` child, `contains(ns,name)`); orchestrate
      derives ns up-front + skips underivable + tuple denylist; `checkOidcGitAgreement`
      pure+tested **but UNWIRED** (no version carries both git-prov+OIDC; add-entry uses
      OCI prov); `tianguis show <url>` (pure `showResult` + `cmdShow`). 17/17 files green.
      **Author-signed namespace-from-OIDC (replace --namespace flag) deferred → #38.**
      **Denylist schema changed: entries now REQUIRE a `namespace` child (S6/migration
      note: existing denylist.kdl entries without namespace are silently skipped).**
- [x] S5 — DONE. `src/tianguis/vendor/resolve.nim` (pure `buildPackagesIndex` /
      `resolveRequire` / `resolveRequires`: bare→map, URL→self-qualify via deriveRepo,
      absent→unresolved); `Version.partiallyResolved` bool added (kdl_io emits only
      when true); 16 resolve tests + 3 roundtrip tests. NO edge persistence / NO
      ingest wiring (= rfc-index-deps first slice). 18/18 files green.
- [ ] (cross-repo, manual) milpa `parse_index` tuple-key update + two-nimkdl fixture
      test — MUST land before S6. **NOT STARTED** — milpa repo has uncommitted
      resolver-swap work (resolver.py/lockfile.py); tuple-keying parse_index ripples
      into Index/Package/resolver. Confirmed milpa `tianguis_client.parse_index:376`
      keys `packages[name]` by bare name (drops collision pair). Timing = open fork.

## ⛔ S6 BLOCKER (wrong-spec escalation — surfaced 2026-06-06, awaiting Corey)
Pre-flight audit of the LIVE index (2613 pkgs) contradicts the RFC's S6:
- **ALL 2509 non-empty namespaces are ORG-ONLY** (`juancarlospaco`, `nim-lang`, …),
  ZERO are `host/org`. + 104 empty. So the RFC's "preserve existing non-empty
  namespaces VERBATIM, derive only the empties" (lines ~185-186, 493) is WRONG: it
  would leave 2509 entries org-only → FAIL gate#3 (`^[a-z0-9.-]+/…` needs a slash) and
  leave them as invalid (host-less) #32 identities. Immutability protects valid #32
  identities; there are NONE yet (all are pre-#32 org-only/empty).
- **0 entries lack a derivable git provenance URL** → the RFC's "drop / manual-patch"
  pre-flight branch is moot; 2612/2613 migrate mechanically. 2508/2509 org-only values
  already equal the derived org (host prepend is consistent + safe).
- **The 1 mismatch = nimkdl** (the #32 artifact). The merged node conflates TWO
  projects: version 2.1.0 (git prov `github.com/greenm01/nimkdl`, milpa-vendored) is
  GREENM01's; version 0.1.4 (OCI `ghcr.io/coreyleavitt/nimkdl`, author-signed) is
  COREYLEAVITT's; node namespace="coreyleavitt" (wrong for 2.1.0). **RFC over-stated
  the damage**: greenm01's version data SURVIVED intact (full content_hash+commit_sha
  on v2.1.0) — NO packages.json re-ingest needed; the repair is a deterministic
  per-version split by provenance.
- **Recommended corrected S6** (NEEDS APPROVAL — it's a spec edit): migrate by
  **deriving host/org per VERSION from its own provenance, then regrouping by
  (namespace,name)** → uniformly upgrades all org-only→host/org AND splits nimkdl into
  two entries in one pass. OCI/author-signed version (v0.1.4) namespace via migration
  fallback (host from `upstream` + existing org → `github.com/coreyleavitt`); true
  OIDC-signer derivation deferred to #38. Edit RFC S6 + "Identity stability" to replace
  preserve-verbatim with derive-all (org-only/empty = pre-#32 forms; immutability binds
  POST-migration).
- Follow-up issues filed this session: **#38** (author-signed namespace from OIDC).
- [ ] S6 — migrate ~2613 idx; **preserve existing namespaces, derive only `""`**;
      pre-flight URL audit of the 101 empties; **manual repair to reconstitute
      greenm01 nimkdl entry**; 6 invariant gates (gate#3 regex now
      `^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$`; gate#4 needs the repair; gate#6 manual in
      milpa repo)

## Round 2 review ledger (stage 2 / architect)
4-lens team (depth/breadth/design/feasibility). All findings clear-best; applied to RFC. No forks.

| id | lens | finding | status |
|----|------|---------|--------|
| F1 | depth | SSH scheme residue: `ssh://git@host/org` leaves `git@` after scheme-strip, colon-rule misfires → wrong host | fixed — parse drops `userinfo@` after scheme-strip |
| F2 | depth | blanket-lowercase merges case-sensitive sr.ht/codeberg `~User` | fixed — per-forge case policy (fold gh/gl/bb; preserve sr.ht/codeberg/fallback) |
| F3 | depth | gitlab nested groups: "first segment" drops subgroup → false-merge | fixed — depth>2 = DerivationError; full support filed **#37** |
| F4/r2-6 | depth/breadth | immutability unenforced; re-derivation drift silent; forge-list growth can break identity | fixed — re-derive-forbidden rule + code-level drift guard + forge-list-evolution constraint |
| F5/feasF9 | depth/feas | gate#3 regex rejects `~`/`.`; doesn't enforce case | fixed — regex `^[a-z0-9.-]+/[a-zA-Z0-9_.~-]+$`; case checked by conformance corpus |
| F8 | depth | OIDC cross-path rule anchored on informational `upstream`, over-broad (rejects fork+sign) | fixed — anchor=version provenance; check fires only when 1 version has both git+OIDC; `upstream` non-identity-bearing |
| F10 | depth | percent-encoded path segments not normalized | fixed — percent-decode in parse |
| design1/breadthR2-4 | design/breadth | string-mangling spec replicated 3x = divergence hazard; no shared corpus | fixed — restructured as ForgeRef parse→normalize→serialize + S2 conformance fixtures |
| design3 | design | no warning against re-deriving identity from current provenance | fixed — "re-derivation forbidden" rule + S6 preserve-existing |
| design4 | design | trust-table row-selection algorithm unspecified | fixed — row-selection flagged as milpa-RFC MUST + sketch |
| design5 | design | namespace=trust-boundary precise for OIDC, approximate for vendor | fixed — "namespace ≠ attestation on vendor path" clarification |
| feasF1/F2/F7 | feas | S1 blast radius: mergeVendored lookup, canonicalize sort, DriftAlert, denylist all bare-keyed | fixed — explicit S1/S4 call-outs w/ line refs |
| feasF3/r2-3 | feas/breadth | S5 has nowhere to persist edges; post-S6 mixed-key index | fixed — S5 pure-fn-only, persistence→rfc-index-deps; transitional mixed-key state documented |
| feasF4/design6 | feas/design | cross-repo gate#6 not runnable as a tianguis test | fixed — reworded as manual blocker note, not gate command |
| feasF6 | feas | gate#4 impossible by re-emit (greenm01 entry was destroyed by merge) | fixed — explicit manual repair step in S6 |
| r2-1 | breadth | lockfile transition window unspecified (soft vs hard cutover) | fixed — soft-cutover transition contract (WARN + `milpa lock` re-lock) as floor |
| r2-2 | breadth | 101 empties: upstream-URL re-derivability unconfirmed | fixed — S6 pre-flight URL audit gate |
| r2-5 | breadth | no author-facing namespace/rejection inspection surface | fixed — Operability section + `tianguis show <url>` on S4 |
| r2-7 | breadth | packages.json poisoning: no audit breadcrumb | fixed — SHOULD record packages.json commit SHA per ingest |
| r2-8/feas | breadth | provenance-missing has no defined behavior | fixed — hard-reject missing provenance at ingest (no trust-table row needed) |
| feasF8 | feas | S3 S1+S2 dependency implicit | fixed — explicit dependency note on S3 |

## Round 1 review ledger (stage 2 / architect)
Findings A–L all fixed; FORK (schema-version) resolved — no versioning pre-v1. (Detail
preserved in git history of this handoff; not re-listed.)

## Follow-up issues
- [x] tianguis **#36** — cross-identity unification after repo/org rename.
- [x] tianguis **#37** — GitLab nested-group (multi-segment) namespaces.

## Key decisions (grill 2026-06-06, hardened r1 + r2)
- Identity = `(host/org, name)`, namespace = attested publisher identity derived from
  the **version's provenance** (`upstream` is informational, not the anchor).
  **Immutable once recorded; re-derivation forbidden; code-level drift guard.**
- Canonicalization = structured `deriveNamespace -> Result[ForgeRef, _]`
  (parse→normalize→serialize), per-forge case policy, single-sourced + a shared
  conformance corpus the Nim bot AND Python milpa both run.
- gitlab depth>2 → derivation failure for now (#37); intra-org collision → reject new /
  preserve existing; missing provenance → hard reject.
- Milpa consumer contract (separate RFC): tuple identity; merged NamedDep+UrlDep w/
  row-selection algorithm; soft-cutover lockfile migration; trust = integrity-anchor
  axis (caveat milpa#103).
