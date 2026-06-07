## KDL projection round-trip tests beyond the empty-index tracer.
##
## Each test asserts: serialize an Index value to KDL, parse it back,
## get the same Index. Bijection through canonical KDL is the load-
## bearing property for spec conformance.

import std/[unittest, sequtils, strutils, tables]
import tianguis/[model, kdl_io]

suite "kdl roundtrip":
  test "one-package zero-versions round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original

  test "packages emerge alphabetical regardless of input":
    proc pkg(name: string): Package =
      Package(name: name, namespace: "ns", upstream: "https://x/" & name)
    let original = Index(
      schemaVersion: 1,
      packages: @[pkg("zoo"), pkg("alpha"), pkg("middle")],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let names = canonicalized.get.packages.mapIt(it.name)
    check names == @["alpha", "middle", "zoo"]

  test "versions emerge in descending semver order regardless of input":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://example.com/chronos",
          versions: @[
            Version(version: "0.4.0", contentHash: "sha256:a",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-01-01T00:00:00Z"),
            Version(version: "0.5.0", contentHash: "sha256:b",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-02-01T00:00:00Z"),
            Version(version: "0.4.5", contentHash: "sha256:c",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-03-01T00:00:00Z"),
          ],
        ),
      ],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let vs = canonicalized.get.packages[0].versions
    check vs.len == 3
    check vs[0].version == "0.5.0"
    check vs[1].version == "0.4.5"
    check vs[2].version == "0.4.0"

  test "version requires map round-trips through KDL (canonical input)":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"results": "^0.5.0", "stew": "^0.1.0"}.toOrderedTable,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  test "version requires keys emit alphabetically regardless of input order":
    let backward = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"stew": "^0.1.0", "results": "^0.5.0"}.toOrderedTable,
        )],
      )],
    )
    let serialized = formatKdl(backward)
    let resultsIdx = serialized.find("\"results\"")
    let stewIdx = serialized.find("\"stew\"")
    check resultsIdx < stewIdx

  test "version with git + oci provenances round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
          versions: @[
            Version(
              version: "0.5.0",
              contentHash: "sha256:abc",
              attestation: "author-signed",
              signedBy: "https://github.com/coreyleavitt",
              publishedAt: "2026-05-25T00:00:00Z",
              provenances: @[
                Provenance(
                  kind: pkGit,
                  url: "https://github.com/coreyleavitt/chronos.git",
                  gitRef: "v0.5.0",
                  commitSha: "abcdef1234567890",
                ),
                Provenance(
                  kind: pkOci,
                  registry: "ghcr.io",
                  repository: "coreyleavitt/chronos",
                  digest: "sha256:fedcba",
                ),
              ],
            ),
          ],
        ),
      ],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  test "one-package one-version round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
          versions: @[
            Version(
              version: "0.5.0",
              contentHash: "sha256:abc",
              attestation: "milpa-vendored",
              signedBy: "milpa-bot",
              publishedAt: "2026-05-25T00:00:00Z",
            ),
          ],
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original

  # ---------------------------------------------------------------------------
  # S3: host/org namespace round-trip + same-name/two-namespace survival
  # ---------------------------------------------------------------------------

  test "host/org namespace (dots and slashes) round-trips intact":
    ## Regression: namespace values like "github.com/coreyleavitt" contain
    ## '.' and '/' which are safe inside KDL quoted strings but must survive
    ## emit → parse unchanged.
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get.packages.len == 1
    check parsed.get.packages[0].namespace == "github.com/coreyleavitt"

  test "two packages with same name but different namespace survive round-trip as two distinct entries":
    ## S3 regression: (namespace, name) is the identity tuple. Two packages
    ## named "nimkdl" under different namespaces must NOT be collapsed, merged,
    ## or dropped at the serialization layer.
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages.len == 2
    # Both namespaces must be present
    let namespaces = parsed.get.packages.mapIt(it.namespace)
    check "github.com/greenm01" in namespaces
    check "github.com/coreyleavitt" in namespaces
    # Both names must be "nimkdl"
    for pkg in parsed.get.packages:
      check pkg.name == "nimkdl"

  # ---------------------------------------------------------------------------
  # S5: partiallyResolved round-trip
  # ---------------------------------------------------------------------------

  test "partiallyResolved=true round-trips through KDL":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: true,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages[0].versions[0].partiallyResolved == true

  test "partiallyResolved=false does not emit the node":
    ## A version with partiallyResolved=false (default) must NOT include the
    ## `partially_resolved` node in its KDL output — keeps the S6 migration
    ## noise-free (2613 existing entries don't gain a spurious field).
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: false,
        )],
      )],
    )
    let serialized = formatKdl(original)
    check "partially_resolved" notin serialized

  test "partiallyResolved=false round-trips as false":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "somepkg", namespace: "github.com/someorg",
        upstream: "https://github.com/someorg/somepkg",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          partiallyResolved: false,
        )],
      )],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get.packages[0].versions[0].partiallyResolved == false

  test "same-name two-namespace pair emerges in canonical (namespace, name) order after round-trip":
    ## canonicalize sorts by (namespace, name). "github.com/coreyleavitt" <
    ## "github.com/greenm01" lexicographically, so coreyleavitt comes first
    ## regardless of insertion order.
    let insertedGreenFirst = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
      ],
    )
    let insertedCoreyFirst = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "nimkdl",
          namespace: "github.com/coreyleavitt",
          upstream: "https://github.com/coreyleavitt/nimkdl",
        ),
        Package(
          name: "nimkdl",
          namespace: "github.com/greenm01",
          upstream: "https://github.com/greenm01/nimkdl",
        ),
      ],
    )
    let r1 = parseKdl(formatKdl(insertedGreenFirst))
    let r2 = parseKdl(formatKdl(insertedCoreyFirst))
    check r1.isOk
    check r2.isOk
    # Both must produce the same canonical ordering
    check r1.get == r2.get
    # coreyleavitt < greenm01 lexicographically → coreyleavitt comes first
    check r1.get.packages[0].namespace == "github.com/coreyleavitt"
    check r1.get.packages[1].namespace == "github.com/greenm01"
