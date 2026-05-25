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
    ├── name: string              (lowercase; matches the manifest convention)
    ├── namespace: string         (OCI / GitHub namespace that owns the name)
    ├── upstream: string          (URL — human reference + source link)
    └── versions: Version[]
        ├── version: string       (semver-shaped identifier)
        ├── contentHash: string   (multihash: "sha256:<hex>")
        ├── requires: Table<string, string>  (dep name → constraint)
        ├── provenances: Provenance[]
        │   └── kind: "git" | "oci"
        │       git: { url, ref, commit_sha }
        │       oci: { registry, repository, digest }
        ├── attestation: string   ("milpa-vendored" | "author-signed")
        ├── signedBy: string      (URI identifying the signer)
        └── publishedAt: string   (ISO 8601 UTC timestamp)
```

Future extensions reserved (parsed but not yet enforced):
`yanked`, `yankedAt`, `yankedReason` per the yank-semantics work
(tianguis #13).

## KDL grammar (canonical)

```kdl
schema_version 1

package "chronos" {
    namespace "coreyleavitt"
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
      "namespace": "coreyleavitt",
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

- `packages`: alphabetical by `name`.
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
