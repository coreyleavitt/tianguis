# tianguis index format — normative grammar

**Spec version**: 1
**Status**: Stabilizing (R1 scope; refinements expected through R5)

This document defines the canonical schema for `index.kdl` and its
auto-derived JSON projection `index.json`. Both formats are
projections of a single data model; the parity invariant
(`format(parse(kdl)) == json` semantically) is enforced via the
`tianguis project --check` command and the corresponding CI workflow.

## Conformance summary

A conformant tianguis implementation MUST:

- Parse and emit both `index.kdl` and `index.json` per the grammar below.
- Reject unknown nodes / properties / keys with stable error codes
  from the IDX-* catalog.
- Emit canonical ordering on every write (packages alphabetical;
  versions descending semver; requires keys alphabetical).
- Preserve provenance declaration order within a version (publisher
  fetch-priority signal).
- Accept either projection as canonical input; the other projection
  is derivable.

## Data model

```
Index
├── schemaVersion: int            (currently always 1)
└── packages: Package[]
    ├── name: string              (lowercase leaf name; matches the manifest convention)
    ├── namespace: string         (attested publisher identity "host/org", e.g.
    │                              "github.com/coreyleavitt"; derived from provenance;
    │                              part of the identity key (namespace, name);
    │                              NEVER empty, NEVER org-only)
    ├── upstream: string          (URL — informational human reference + source link;
    │                              NOT identity-bearing; identity derives from
    │                              the version's provenance, never this field)
    └── versions: Version[]
        ├── version: string       (semver-shaped identifier)
        ├── contentHash: string   (multihash: "sha256:<hex>")
        ├── requires: Table<string, string>  (dep name → constraint; keys are BARE
        │                                     names — see "Transitional mixed-key note")
        ├── provenances: Provenance[]
        │   └── kind: "git" | "oci"
        │       git: { url, ref, commit_sha }
        │       oci: { registry, repository, digest }
        ├── attestation: string   ("milpa-vendored" | "author-signed")
        ├── signedBy: string      (URI identifying the signer)
        └── publishedAt: string   (ISO 8601 UTC timestamp)
```

### Identity key

The **identity key** for a package is the pair `(namespace, name)`.

- `namespace` is a canonical string of the form `host/org` derived from the
  version's provenance URL via the canonicalization algorithm below.
- `name` is the lowercase leaf name the `.nimble` file declares.
- Two packages that share a `name` but have different `namespace` values are
  **distinct entries** (the #32 nimkdl collision case).  Two packages that share
  a `namespace` but differ in `name` are equally distinct.
- `(namespace, name)` is **immutable once recorded** (commitment #8): provenance
  may change (fork move, mirror), but the derived identity is pinned at first ingest.

### Namespace canonicalization (NORMATIVE)

This section is the authoritative cross-language specification of `deriveNamespace`.
All implementations (Nim, Python, future Rust) derive the same `namespace` value from
a raw URL by executing these three phases against a shared conformance corpus
(`spec/fixtures/derive-namespace.json`).

```
ForgeRef = (host: string, org: string)
deriveNamespace(raw) -> Result[ForgeRef, DerivationError]

DerivationError =
  | derrUnparseable        -- no usable host/path could be parsed
  | derrNoOrg              -- parsed to a bare host with no org segment
  | derrGitlabNestedGroup  -- gitlab.com path depth > 2 (#37)
```

**Phase 1 — Parse** `raw` into `(scheme?, userinfo?, host, port?, pathSegments[])`:

- Accept `https://`, `http://`, `git://`, `ssh://`, and the scheme-less SSH short
  form `git@host:org/repo`.
- After stripping any scheme, **drop any `userinfo@` prefix** (fixes
  `ssh://git@host/…` where `git@` survives scheme-stripping and would otherwise
  contaminate the host field).
- The SSH short form `git@host:org/repo` uses the host before the colon and the
  path after it.
- Drop any `:port`, `?query`, and `#fragment`.
- **Percent-decode** each path segment (RFC 3986); do not decode the host.
- Input that yields no identifiable host returns `derrUnparseable`.

**Phase 2 — Normalize** the parsed fields:

- **Host:** strip a leading `www.`; lowercase the entire host; strip a trailing `.`.
  IDN/punycode hosts are used as-is (transcoding is out of scope).
- **Path:** drop empty segments (collapses repeated `/`); strip a trailing `.git`
  from the final path segment.
- **Org/repo split** and **case-folding of `org`** are per the forge-topology table.

**Phase 3 — Forge topology** — normalized host → org-segment count + owner-case policy:

| Host | Org segments | Owner case |
|---|---|---|
| `github.com` | 1 | **fold** (case-insensitive owners) |
| `gitlab.com` | 1 (see nested-group rule) | **fold** |
| `bitbucket.org` | 1 | **fold** |
| `codeberg.org` | 1 | **preserve** (Gitea — case-sensitive owners) |
| `git.sr.ht` | 1 (`~user`) | **preserve** (case-sensitive) |
| *any other host* (fallback) | 1 | **preserve** (unknown semantics → safest) |

- **GitLab nested groups** (`gitlab.com/group/subgroup/project`): a GitLab URL with
  path depth > 2 returns `derrGitlabNestedGroup` — rejected at ingest, never silently
  mis-derived. Depth-2 GitLab URLs derive normally. First-class nested-group support
  is filed as #37 (purely additive; accepted URLs later become accepted, so no
  existing pinned identity breaks).
- A path that yields no org segment (bare host, or path too short) returns `derrNoOrg`.
  An entry with `namespace ""` is **never** stored.

**Phase 4 — Serialize:** `namespace = host & "/" & org`.

**Conformance corpus:** `spec/fixtures/derive-namespace.json` is the
single-source-of-truth oracle. Every implementation MUST pass every case. Cases use
string error codes matching the `DerivationError` enum symbol names exactly
(`derrNoOrg`, `derrGitlabNestedGroup`, `derrUnparseable`).

**Forge-list evolution constraint:** a host may be added to the topology table only
if it produces byte-identical output to the fallback rule for every URL of its form.
A forge requiring a different rule (different org-segment count or different case
policy) is a **breaking change** requiring a spec-version bump and a migration, because
entries already ingested from that host were pinned under the old derivation.

### Per-version attestation-anchor algorithm (NORMATIVE)

`deriveVersionNamespace` selects the identity anchor for a single version and derives
its `host/org` namespace by applying `deriveNamespace` (Phase 1–4 above) to that anchor.
The procedure is deterministic and MUST be executed in the order below; the first
matching branch wins:

1. **pkGit provenance present** — use the first `provenance` node of `kind "git"` in
   declaration order; extract its `url` field; apply `deriveNamespace(url)`.  This is
   the vendor-en-absentia path: the forge org that owns the upstream repo is the
   attested publisher identity.

2. **No git provenance; author-signed `signed_by` present** — use the `signed_by` field
   value.  On the author-signed path this is a GitHub Actions OIDC SAN URL (e.g.
   `https://github.com/coreyleavitt`); apply `deriveNamespace(signed_by)`.

   > **`signed_by` format (NORMATIVE).** An author-signed `signed_by` value is a parseable
   > identity SAN URL — the Subject Alternative Name from the keyless-OIDC signing
   > certificate that was cosign-verified (Fulcio cert + Rekor inclusion) at ingest. The
   > canonical GitHub Actions form is
   > `https://github.com/<org>/<repo>/.github/workflows/<workflow>.yaml@<ref>` (where
   > `<ref>` is e.g. `refs/heads/main` or `refs/tags/v1`). Deriving the namespace applies
   > `deriveNamespace(signed_by)`, which takes only the `host/org` portion; the repo path,
   > the workflow suffix, and the `@<ref>` fragment are discarded.
   >
   > **Derivation is forge-agnostic; issuer trust is a separate, orthogonal gate.**
   > `deriveNamespace` is host-agnostic by design (named forges + a generic `host/org`
   > fallback) — it does NOT restrict identity to `github.com`. The set of *trusted OIDC
   > issuers* is enforced upstream of derivation, at the cosign-verify step in
   > `commit-entry.yaml` (`--certificate-oidc-issuer`), which currently accepts only the
   > GitHub Actions issuer `https://token.actions.githubusercontent.com` and is expandable
   > as other issuers (GitLab CI, etc.) are validated. A `signed_by` from a non-GitHub
   > forge would derive a perfectly valid `host/org` namespace; whether it is *accepted*
   > is decided by that issuer-trust gate, never by the (forge-agnostic) namespace
   > derivation. Do not conflate the two: identity derivation answers "whose namespace is
   > this?", the verify gate answers "is this signer's issuer one we trust?".
   >
   > A milpa-vendored `provenance` string is NOT a valid identity anchor for this branch —
   > vendor-en-absentia packages must carry a git `provenance.url` (branch 1). It is a
   > freeform provenance record, not a signer identity.

3. **Neither present** — the version has no resolvable provenance anchor; derivation
   fails with a hard error at ingest.  A conformant index NEVER contains a version whose
   namespace was derived without a valid anchor from branch 1 or 2.

**Immutability and the S6 migration.** Commitment #8 (identity immutable once recorded)
binds to the `host/org` values produced by this algorithm and stored by the S6
migration.  Pre-#32 stored values (org-only such as `nim-lang`, or empty `""`) are not
valid outputs of `deriveVersionNamespace` and are NOT covered by the immutability
guarantee — S6 replaces them via derive-all-per-version; post-migration, any re-derived
namespace that differs from the stored `host/org` is a drift violation.

**The nimkdl split (live-index example).** The 2613-package live audit found all 2509
non-empty namespaces are org-only (pre-#32); 104 are empty.  The sole identity conflict
is `nimkdl`, where greenm01 git versions and a coreyleavitt OCI version were conflated
under namespace `coreyleavitt`.  Per-version derivation resolves it without re-ingest:
greenm01's versions carry git `provenance.url` values that derive `github.com/greenm01`;
coreyleavitt's OCI version carries a `signed_by` SAN that derives
`github.com/coreyleavitt`.  The result is two distinct `(namespace, name)` index entries
with no version data lost.

### Same-name, two-namespace entries

Two packages sharing a leaf `name` under different namespaces are **distinct index
entries** — both are present simultaneously. Example (the #32 collision pair):

```kdl
package "nimkdl" {
    namespace "github.com/greenm01"
    upstream (url)"https://github.com/greenm01/nimkdl"
    ...
}

package "nimkdl" {
    namespace "github.com/coreyleavitt"
    upstream (url)"https://github.com/coreyleavitt/nimkdl"
    ...
}
```

In JSON projection these appear as two objects in the `packages` array, both with
`"name": "nimkdl"` but different `"namespace"` values.

### Transitional mixed-key note

Post-#32 (this slice) and pre-`rfc-index-deps.md` (which introduces qualified dep
edges): a version's `requires` keys are still **bare names** (e.g. `"chronos"`), not
qualified `host/org/name` keys.  A consumer MUST treat `requires` keys as bare names
and resolve them against the index's `(namespace, name)` pairs at lookup time.  This
is intentional — the bare-name world is resolved at the ingest membrane, not by
inflating every stored `requires` key prematurely.

Future extensions reserved (parsed but not yet enforced):
`yanked`, `yankedAt`, `yankedReason` per the yank-semantics work
(tianguis #13).

## KDL grammar (canonical)

```kdl
schema_version 1

package "chronos" {
    namespace "github.com/coreyleavitt"
    upstream (url)"https://github.com/coreyleavitt/chronos"

    version "0.5.0" {
        content_hash "sha256:abc..."

        requires {
            "results" "^0.5.0"
            "stew"    "^0.1.0"
        }

        provenance {
            kind "git"
            url (url)"https://github.com/coreyleavitt/chronos.git"
            ref "v0.5.0"
            commit_sha "abc123..."
        }
        provenance {
            kind "oci"
            registry "ghcr.io"
            repository "coreyleavitt/chronos"
            digest "sha256:def..."
        }

        attestation "author-signed"
        signed_by "https://github.com/coreyleavitt"
        published_at "2026-05-25T00:00:00Z"
    }
}
```

URL-typed values carry the `(url)` annotation per
[[kdl-url-convention]]; parsers MUST accept both the annotated and
plain string forms for backward compatibility.

## JSON projection (auto-derived)

```json
{
  "schema_version": 1,
  "packages": [
    {
      "name": "chronos",
      "namespace": "github.com/coreyleavitt",
      "upstream": "https://github.com/coreyleavitt/chronos",
      "versions": [
        {
          "version": "0.5.0",
          "content_hash": "sha256:abc...",
          "requires": {"results": "^0.5.0", "stew": "^0.1.0"},
          "provenances": [
            {"kind": "git", "url": "...", "ref": "v0.5.0", "commit_sha": "..."},
            {"kind": "oci", "registry": "ghcr.io", "repository": "...", "digest": "..."}
          ],
          "attestation": "author-signed",
          "signed_by": "https://github.com/coreyleavitt",
          "published_at": "2026-05-25T00:00:00Z"
        }
      ]
    }
  ]
}
```

Keys use snake_case (matching KDL node names). Both projections carry
the same semantic content; parity is asserted programmatically.

## Canonical ordering

- `packages`: ordered by `(namespace, name)` — namespace first (lexicographic),
  then name within a namespace (lexicographic). This means all entries for
  `github.com/greenm01` appear before `github.com/coreyleavitt` when sorted
  lexicographically, and within a namespace entries are sorted by leaf name.
- `versions` (per package): descending semver. Pre-release / build-
  metadata suffixes are stripped for ordering purposes; full semver
  2.0.0 prerelease comparison is a future refinement.
- `requires` keys: alphabetical.
- `provenances`: declaration order preserved (the publisher signals
  fetch priority).

`canonicalize(Index) → Index` is idempotent and is invoked
automatically by both emitters before output.

## Error catalog (IDX-*)

| Code | Triggered when |
|---|---|
| `IDX-KDL-PARSE` | KDL syntax error reported by the kdl library |
| `IDX-JSON-PARSE` | JSON syntax error reported by stdlib `std/json` |
| `IDX-NODE-UNKNOWN` | A KDL node or JSON key is not in the schema's allowed set for its context |
| `IDX-PROP-UNKNOWN` | A KDL property (key=value entry) is not in the allowed set (reserved; not yet emitted at v1) |
| `IDX-FIELD-MISSING` | A required field is absent (reserved; not yet enforced at v1) |
| `IDX-TYPE-MISMATCH` | A field's value is the wrong type, including unknown discriminator values |

Errors carry `code`, human-readable `message`, and 1-based
`line`/`col` (when source position is available — KDL provides them;
JSON does not).

## CLI contract

`tianguis project` synchronizes the two projections:

- No flags → regenerates `index.json` from `index.kdl` (overwrites
  any existing JSON file). Exit code 0 on success, 1 on KDL parse
  failure or missing source.
- `--check` → verifies the existing `index.json` is byte-equivalent
  (semantic) to what would be regenerated. Exit code 0 on parity, 1
  on missing source / KDL error, 2 on drift / JSON error.

CI workflows MUST run `tianguis project --check` so PRs that mutate
one projection without the other fail the build.
