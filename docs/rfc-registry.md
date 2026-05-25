# RFC: tianguis — the milpa package registry

**Status**: Proposed (companion to `rfc-distribution-and-publishing.md` and `rfc-content-addressed-identity.md`)
**Author**: Corey Leavitt
**Date**: 2026-05-24

> Companion RFCs referenced by filename below live in the
> [coreyleavitt/milpa](https://github.com/coreyleavitt/milpa) repo
> under `docs/`.

## Why this RFC exists

`rfc-distribution-and-publishing.md` settled the *substrate* question:
milpa-aware packages ship as OCI artifacts on existing OCI hosts
(GHCR, Docker Hub, Harbor, Zot, etc.). Storage, DDoS, immutability,
attestation, and federation are inherited from the CNCF ecosystem
rather than rebuilt.

What that RFC did NOT settle is the *discovery + metadata* layer.
Knowing `ghcr.io/author/pkg@sha256:abc...` lets milpa fetch a known
artifact; it does not let a user `milpa add chronos`. nim-lang/packages
provides today's discovery answer — a JSON file of name → git URL
entries, PR-curated.

The PR-curation model is the central defect. nim-lang/packages PRs
routinely languish for weeks. The latency is not in network or
infrastructure; it is in the human review step. Any registry milpa
ships must structurally eliminate that step, not merely speed it up.

This RFC commits milpa to **tianguis** — an automated, cryptographically-
gated package index whose mutation path has no human gatekeeper. It
specifies:

1. The principle: cosign attestation is the sole gatekeeper.
2. The publishing flow for authors who have adopted milpa.
3. The vendor-en-absentia flow for the unadopted majority on day one.
4. The index format (KDL canonical, JSON projection).
5. Federation, frontend, and hosting decisions.
6. Cession protocol when an author opts in over a vendored entry.

## The principle

> The index mutates only under cryptographic verification. There is no
> human merge step on the publishing path. Latency from author intent
> to package availability is bounded by automation, not curation.

Concretely: a release tag pushed by a package author results in an
index entry within ~60 seconds, with no human between the two events.
A vendored entry written by the milpa-bot for an unadopted upstream
package is written under the bot's own attested identity, with the
same automation discipline.

This is the load-bearing commitment. Every other decision in this RFC
follows from it.

## Background: why nim-lang/packages is structurally insufficient

A single JSON file at `github.com/nim-lang/packages` whose entries
look like:

```json
{"name": "results", "url": "https://github.com/arnetheduck/nim-results", "method": "git"}
```

Publishing means submitting a PR adding an entry. Real-world latency
for that PR to merge ranges from days to weeks. The gap list:

1. **Curation latency** — weeks of delay between author submitting and
   package being installable.
2. **No version visibility** — entry points at a git URL; "what
   versions exist" is whatever tags the upstream happens to have.
3. **No content verification** — bytes can change after listing
   (force-push, tag rewrite); no record of what was once true.
4. **No attestation** — entry proves nothing about author identity.
5. **No yank semantics** — bad releases stay listed; no mark-as-bad.
6. **No mirror chain** — if upstream URL dies, the package vanishes.
7. **No federation** — single canonical index; mirrors must copy the
   entire repo manually.

(2), (3), (4), (5), (6) are inheritable from the OCI substrate + the
content-addressed identity model. (1) and (7) require registry-side
architectural decisions. This RFC addresses both.

## Prior art

**Go modules** — no central registry. Imports resolve directly from
URLs (`import github.com/foo/bar`). The Go checksum database
(`sum.golang.org`) is append-only + transparency-log-backed —
verification infrastructure, not curation. Discovery (`pkg.go.dev`) is
a separate concern from resolution. *No human curates anything on the
resolution path.*

**Sigstore / Rekor** — the transparency-log model for OCI artifact
attestation. Author signs via OIDC; signature lands in Rekor (public
append-only log); consumers verify against Rekor without trusting any
central authority. *Cryptographic verification is the gatekeeper, not
human review.*

**Debian + nixpkgs** — distro-maintainer vendoring model. Maintainers
package upstream software without upstream's involvement, sign as the
distro, cede gracefully when upstream adopts. Authors uninvolved;
ecosystem-wide coverage on day one. Decades of operational precedent.

**Cargo + crates.io** — central index with automated publish (`cargo
publish` → API endpoint → immediate listing). No PR review, but
requires a hosted backend and central trust. Faster than
nim-lang/packages, but operationally heavier than what milpa needs.

**Helm + OCI** — Helm charts publish as OCI artifacts; no central Helm
registry; consumers point at any OCI host. Validates the "OCI is
sufficient substrate" argument for source distribution.

The pattern across modern systems: *cryptographic verification
replaces human review on the publishing path*. tianguis adopts this
pattern wholesale.

## The model

### Resolution path (decoupled from the index)

A direct OCI URL in a manifest resolves without touching the index:

```kdl
deps {
    chronos oci="ghcr.io/coreyleavitt/chronos" digest="sha256:abc..."
}
```

This is the Go-modules-style path: if you know what you want, the
index is not on the critical path. The index can lag by hours and
existing builds still resolve. New direct-URL adds work without
waiting on anything.

A name-only dep resolves *through* the index:

```kdl
deps {
    chronos "^0.5.0"
}
```

milpa hits the index, finds entries matching `chronos`, picks the
highest version satisfying the constraint, fetches by the recorded
provenance (OCI digest or git URL+ref), verifies content hash.

### Index entry shape (canonical KDL)

```kdl
package "chronos" {
    namespace "coreyleavitt"        // OCI/GH namespace owning this name
    upstream "https://github.com/coreyleavitt/chronos"

    version "0.5.0" {
        content_hash "sha256:abc..."
        provenance {
            kind "oci"
            registry "ghcr.io"
            repository "coreyleavitt/chronos"
            digest "sha256:def..."
        }
        provenance {
            kind "git"
            url "https://github.com/coreyleavitt/chronos.git"
            ref "v0.5.0"
            commit_sha "..."
        }
        attestation "author-signed"
        signed_by "https://github.com/coreyleavitt"
        published_at "2026-04-12T14:22:01Z"
    }

    version "0.4.9" {
        content_hash "sha256:..."
        provenance { kind "git"; url "..."; ref "v0.4.9"; commit_sha "..." }
        attestation "milpa-vendored"
        signed_by "milpa-bot via GH OIDC"
        published_at "2026-03-30T08:00:00Z"
    }
}
```

Multi-version per package; multi-provenance per version
(content-addressing RFC Phase D shape). Attestation level is a
first-class field, not an afterthought.

### Format: KDL canonical, JSON projection auto-published

The canonical source-of-truth is `index.kdl`. A `index.json` is
auto-derived and committed alongside; CI asserts byte-equivalence of
the semantic content.

Rationale:
- **KDL canonical** for consistency with milpa.kdl / milpa.lock, for
  inline comments on bot-written entries (vendoring rationale,
  opt-out provenance, force-push notes), and for human readability
  during audits.
- **JSON projection** for ecosystem interop. The index is a
  cross-implementation surface that non-milpa tooling (dashboards,
  mirrors, search engines, ad-hoc `jq` scripts) will want to read.
  Requiring a KDL parser everywhere taxes adoption for tooling that
  has no other reason to depend on milpa's format choices. Matches the
  rationale in `rfc-property-based-testing.md` for JSON conformance
  fixtures.

Spec: KDL form is normative for conformance; JSON form is a
convenience projection. milpa-the-tool reads KDL via its existing
parser; the static frontend reads JSON via `JSON.parse`.

### Publishing: adopted authors

Author flow:

1. Author installs the `tianguis-publish` GitHub App on their package
   repo (one-time, ~30 seconds). App installation = ownership proof
   for that GitHub namespace.
2. Author tags a release: `git tag v1.2.3 && git push --tags`.
3. The author's repo runs a `tianguis-publish.yml` workflow (template
   provided by tianguis) that:
   - Builds + pushes the OCI artifact under their namespace
   - Signs via cosign keyless (GH Actions OIDC)
   - Fires `repository_dispatch` against `coreyleavitt/tianguis` with
     the OCI URL, digest, and attestation reference
4. The tianguis repo workflow receives the dispatch, runs `cosign
   verify` against the artifact, checks that the signer identity is a
   GitHub OIDC token whose `repository_owner` matches the entry's
   declared namespace, commits the version entry to `index.kdl`,
   regenerates `index.json`, lets GH Pages redeploy.

Time from `git push --tags` to package being installable: under 60
seconds. No PR. No human review. Verification is cryptographic at
every step.

### Publishing: vendor-en-absentia (the unadopted majority)

A scheduled workflow in the tianguis repo (`cron: daily`) walks
`nim-lang/packages.json` plus any explicit seed list, and for each
package without an authoritative tianguis entry:

1. `git ls-remote` to find tags. Selection heuristic, in order:
   - Semver-shaped tags (`vN.N.N`, `N.N.N`)
   - Any tag
   - HEAD of default branch, recorded as version
     `0.0.0+commit-<short-sha>`
2. Shallow-clone at the selected ref, compute content_hash per the
   identity algorithm.
3. Sign as `milpa-bot` (GH Actions OIDC → cosign keyless → Rekor).
4. Write a version entry with `attestation "milpa-vendored"`.
5. Commit.

Day one, tianguis covers the entire nim package ecosystem with
verifiable content hashes. Users get strictly better integrity than
nimble (bytes pinned, force-pushes detected, lockfiles portable)
without waiting for anyone to opt in.

The vendored entry transparently labels its trust level. The
attestation field distinguishes `author-signed` from `milpa-vendored`;
consumers can configure a minimum-acceptable level per project (default
accepts both; paranoid mode accepts only `author-signed`).

### Cession protocol

When an author later installs the `tianguis-publish` GitHub App on a
repo with existing vendored entries:

1. The bot detects the installation event.
2. New version entries from the author override the bot's pattern for
   that namespace.
3. The bot stops auto-vendoring future versions for that package.
4. Existing vendored entries remain in the index — they are referenced
   by extant lockfiles and must continue to resolve. The content_hash
   is the same regardless of who signed it.

Existing lockfiles are unaffected (content_hash unchanged). New
resolutions prefer the higher-attestation entry. The handoff is
invisible to consumers; it shows up only as a more trusted
attestation label on future versions.

### Force-push handling

The vendoring bot reruns daily. If a tag's content_hash drifts from
the recorded entry, the bot does **not** silently update — that would
break extant lockfiles.

Behavior on drift:
- Old entry retained verbatim. Existing lockfiles continue to resolve.
- The drift is recorded in an alert log committed to the tianguis repo
  (`alerts.kdl`).
- A new version entry is NOT auto-written. Force-pushes are rare and
  warrant a human look. The package is flagged as "upstream
  unstable"; the alert names the package and the drift detection time.
- If the upstream tag stabilizes (rehashed-and-stable on subsequent
  runs), the alert can be cleared and a new version recorded with a
  suffix like `vX.Y.Z+rehashed-<date>`.

Adopted authors hit the same logic on their side: a force-pushed
release tag fails the verification step in the publish workflow
because the OCI digest stored in the index won't match a re-pushed
artifact. Force-pushing release tags is structurally discouraged.

### Direct OCI URL fetches never consult the index

A manifest entry of the form `oci="..." digest="..."` resolves
directly. No index lookup. This is the Go-modules-style escape hatch:
if a user knows what they want, the index is not on the critical
path. Useful for:

- Pre-release / experimental publishes not registered with tianguis
- Private packages on a self-hosted OCI registry
- CI / air-gapped environments with no tianguis access
- Sovereign deployments using a forked or mirrored index

Resolution still verifies content_hash; cosign verification of OCI
direct-URL deps follows the same `verification { ... }` manifest block
specified in `rfc-distribution-and-publishing.md`.

### Self-mirrors federation (#91)

Publisher-declared self-mirrors (top-level `mirrors { mirror (url)
"..." }` block in a package's milpa.kdl, per the resolver's existing
support) get extracted into the tianguis index per version. Consumers
fetch the version entry, see the mirror list, try alternates on
fetch failure. The mirror list is part of the version entry's
provenance block — multi-provenance shape (content-addressing RFC
Phase D) accommodates this natively.

The author's publish workflow extracts the mirror declarations from
their milpa.kdl and passes them in the `repository_dispatch` payload;
the bot writes them into the tianguis entry's provenance section. No
separate signaling channel needed.

## Federation

tianguis is one canonical index, but:

- The index repo can be mirrored anywhere via `git clone --mirror`.
- milpa accepts a configurable list of index URLs
  (`MILPA_INDEX_URLS` env var or manifest setting), tries in order,
  records which served the entry.
- Corporate / sovereign / air-gapped use cases: run a local mirror,
  point milpa at it. No coordination with tianguis required.

Federation discipline:
- Mirrors are byte-identical copies of the canonical index. No mirror
  may diverge in attestation status or content_hash without forking.
- A fork (divergent index) is a first-class option, but mirror-vs-fork
  must be declared. Mirrors keep tianguis's signing chain; forks
  re-attest under their own bot identity.

## Frontend (deferred to its own issue)

A static SPA over the JSON projection provides search, package pages,
dependency-graph visualization, and recently-published browsing.
Implementation:

- TypeScript + Astro on GH Pages
- Search via [Pagefind](https://pagefind.app/) (build-time indexing,
  client-side query, no backend)
- Package pages rendered from `index.json`
- Dep-graph viz via sigma.js or d3

This is deferred from this RFC to its own implementation issue. The
substrate decision (KDL+JSON, GH Pages, no dynamic backend) is
correct regardless of frontend timing.

When a custom domain is acquired, GH Pages handles the CNAME with
zero infrastructure change.

## Hosting

- Index repo: `coreyleavitt/tianguis`
- Index served at `https://tianguis.coreyleavitt.dev/` (or similar)
  via GH Pages
- Future custom domain: `tianguis.dev` or similar; CNAME to GH Pages
- Static SPA frontend: same GH Pages deployment, separate path
- No VPS required. No dynamic backend. No database.

The vendoring bot, the publishing dispatch handler, and the static
site build are all GitHub Actions workflows in the tianguis repo.
Total infrastructure: one GitHub repo.

## Naming

**tianguis** — Nahuatl for open-air market, the central commercial
institution of pre-Columbian Mesoamerica (the Tlatelolco tianguis was
the largest in the Americas at contact). It is exactly where milpa
growers brought their corn, beans, and squash to trade. The metaphor
is precise: a marketplace where milpa users find packages = a
tianguis where farmers bring their harvest.

Stays in milpa's established Mesoamerican naming lane. Tianguis is
purely commercial vocabulary in modern Mexican Spanish, used daily;
not sacred, not ceremonial, not extractive.

## Phasing

### Phase R1 — index format + spec

1. Specify `index.kdl` schema in this RFC's "Index entry shape"
   section.
2. Specify the JSON projection algorithm.
3. Bootstrap `coreyleavitt/tianguis` repo with empty `index.kdl` +
   `index.json` + CI parity check.

**Estimated effort:** 1-2 days.

### Phase R2 — vendor-en-absentia bot

1. GH Actions cron workflow walking `nim-lang/packages.json`.
2. Tag selection + content_hash computation + cosign signing as
   milpa-bot.
3. Commit logic with force-push detection + alert handling.

**Estimated effort:** 4-6 days.

### Phase R3 — adopted-author publish flow

1. `tianguis-publish` GitHub App scaffolding.
2. `tianguis-publish.yml` workflow template for author repos.
3. `repository_dispatch` receiver workflow in tianguis repo.
4. Cosign verification + identity-vs-namespace matching.
5. Cession-protocol logic (App installation → stop vendoring this
   namespace).

**Estimated effort:** 6-9 days, including App registration friction.

### Phase R4 — milpa client integration

1. milpa's registry path reads from tianguis instead of (or alongside)
   nim-lang/packages.
2. Configurable index URLs (`MILPA_INDEX_URLS`).
3. Attestation-level filtering (`verification { min_attestation
   "author-signed" }`).

**Estimated effort:** 3-5 days.

### Phase R5 — static frontend (separate issue)

Deferred from this RFC. File as separate issue once R1-R4 are
operational and a real index exists to render.

### Phase R6 — opt-out + ecosystem care (ongoing)

1. Denylist mechanism for authors who request removal.
2. Documentation for authors about what vendor-en-absentia does and
   how to opt out or upgrade to signed.
3. Public log of bot operations (the `alerts.kdl` file already
   provides this for drift events; expand for vendoring events).

## Open design questions

### 1. Name collision policy

Two repos both claim `chronos`. The first to publish wins?
First-to-register-via-App wins? Manual arbitration?

Recommendation: first-publish-wins via the bot's vendoring (it processes
nim-lang/packages in order; collisions there are already resolved by
the upstream PR ordering). For adopted-author conflicts: App
installation on a repo that doesn't match the declared namespace is
rejected at the verification step. Genuine ownership disputes are the
only human-touch surface and are extremely rare; a tianguis-repo
issue is the resolution path.

### 2. nim-lang/packages relationship

Is tianguis a *replacement* for nim-lang/packages, an *augmentation*,
or independent?

Recommendation: augmentation initially. tianguis pulls from
nim-lang/packages as its seed list. Authors who publish to tianguis
also remain in nim-lang/packages (for nimble consumers). Over time,
if tianguis adoption is significant, the relationship may evolve.

### 3. Attestation level granularity

Two levels (`milpa-vendored` vs `author-signed`) or more?

Recommendation: start with two. A third tier (`author-signed +
slsa-build-attested`) becomes meaningful once SLSA provenance is in
broad use; deferred until then.

### 4. Index sharding

A single `index.kdl` works at current ecosystem scale (~2500 nim
packages). At what point does this become unwieldy?

Recommendation: defer until the file is >50MB or queries become slow.
At that point, shard by first letter (`index-a.kdl`, etc.) with a
top-level manifest. Standard registry pattern.

### 5. Yank semantics

How does an author mark a published version as yanked?

Recommendation: a yank is a new dispatch event from the author's
workflow that sets `yanked: true` on a specific version entry.
Lockfiles already pinned to that version continue to resolve
(immutability); new resolutions skip yanked entries unless an explicit
`--allow-yanked` flag is used. Bot-vendored entries can be yanked by
the upstream maintainer once they install the App, or by tianguis
admins via PR for emergencies (CVEs, malware).

### 6. Bot identity rotation

`milpa-bot` signs vendored entries via GH Actions OIDC. The OIDC
identity is tied to the tianguis GH Actions workflow. If the workflow
moves or the org name changes, old signatures retain their original
identity (Rekor is append-only) but new signatures use the new
identity.

Recommendation: document the canonical bot identity URI in the spec;
verification accepts any of a declared set of past identities.
Rotation is a spec patch, not a structural problem.

### 7. Index-write rate limiting

If a malicious actor floods the dispatch endpoint with rejected
dispatches (failed cosign verifications), CI minutes get consumed.

Recommendation: per-source-repo rate limiting in the workflow; reject
dispatches from non-App-installed repos at the receiver. Standard
abuse-mitigation engineering, not a structural concern.

### 8. Frontend repo split

Should the static SPA frontend live in the tianguis repo or in its
own repo?

Recommendation: same repo, separate directory. GH Pages serves both
the index files and the SPA from one repo with one Actions workflow.
Splitting introduces deployment coordination without benefit.

## Acceptance: testable invariants

The model is right when:

1. An author publishes via the `tianguis-publish` App, and the package
   is installable via `milpa add <name>` within 60 seconds of `git
   push --tags`.
2. The vendoring bot's daily run covers every nim-lang/packages entry
   that has at least one tag, producing a verifiable content_hash
   entry signed by milpa-bot.
3. A force-push to a vendored upstream tag does NOT silently update
   the tianguis entry. The drift is logged; existing lockfiles
   continue to resolve.
4. When an author installs the App on a previously-vendored package,
   subsequent versions are signed by them, prior vendored versions
   remain functional, and the bot ceases auto-updating.
5. A direct `oci="..."` manifest dep resolves without any index
   contact.
6. A consumer configuring `verification { min_attestation
   "author-signed" }` cannot resolve a `milpa-vendored` entry; the
   error names the package and the attestation gap.
7. A mirror of the tianguis index (set up via `git clone --mirror` +
   GH Pages on another repo) serves identical bytes; milpa fetches
   through it transparently with the appropriate config.
8. KDL and JSON projections of `index.kdl` are byte-equivalent in
   semantic content; the CI parity check passes on every commit.

## Issues this RFC will spawn

To be filed under a new milestone "registry — tianguis
(rfc-registry)":

- R1: index format spec + `coreyleavitt/tianguis` repo bootstrap +
  CI parity check
- R2: vendor-en-absentia bot (cron workflow)
- R3a: `tianguis-publish` GitHub App scaffolding
- R3b: author-side `tianguis-publish.yml` workflow template
- R3c: dispatch receiver workflow + cosign verification
- R3d: cession protocol on App installation
- R4: milpa client reads from tianguis (registry path refactor)
- R4a: configurable index URL list
- R4b: `verification { min_attestation }` manifest grammar extension
- R5: static SPA frontend (deferred; file when R1-R4 operational)
- R6: opt-out denylist + public log of bot operations
- Force-push detection + alert log shape
- Yank semantics implementation
- Name-collision dispute resolution policy doc
- nim-lang/packages relationship doc (long-term)

## Connections

- `rfc-distribution-and-publishing.md` — OCI substrate decision. This
  RFC builds the discovery/metadata layer on top.
- `rfc-content-addressed-identity.md` — identity model the index
  entries record. Multi-provenance shape (Phase D) accommodates
  multiple sources per version.
- `rfc-pluggable-fetchers.md` — F1 (Git) + F6 (OCI) are the transports
  the index entries reference.
- `rfc-multi-impl-strategy.md` — both Python and Rust milpa
  implementations consume the same index. Format choice (KDL+JSON)
  serves both.
- Existing milpa #91 (publisher-side self-mirrors) — naturally
  expressed via per-version provenance lists in tianguis entries.

## What this RFC does NOT commit milpa to

- A specific frontend stack (deferred to its own issue)
- A custom domain (eventual, not blocking)
- A dynamic backend service (intentionally avoided; can be added
  later as a separable concern without changing the substrate)
- A specific cosign verification library on the milpa client side
  (decided per impl; spec only requires Sigstore-compatible
  verification)
- A formal partnership or coordination requirement with
  nim-lang/packages maintainers (the augmentation model needs nothing
  from them)
- Replacement of any existing publishing path; nimble + bare-git +
  direct-OCI-URL all remain first-class
