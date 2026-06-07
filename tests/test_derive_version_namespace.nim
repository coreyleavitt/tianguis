## Tests for deriveVersionNamespace — SSOT per-version attestation anchor.
##
## RED first: all tests written before the proc exists in namespace.nim.

import std/[unittest, tables]
import tianguis/namespace
import tianguis/model
import tianguis/vendor/merge
import tianguis/vendor/upstream
import tianguis/vendor/tagselect

# ---------------------------------------------------------------------------
# Helpers for constructing test Versions
# ---------------------------------------------------------------------------

proc makeGitVersion(gitUrl: string): Version =
  Version(
    version:     "1.0.0",
    contentHash: "sha256:aabbcc",
    attestation: "milpa-vendored",
    signedBy:    "",
    publishedAt: "2026-01-01T00:00:00Z",
    provenances: @[Provenance(
      kind:      pkGit,
      url:       gitUrl,
      gitRef:    "v1.0.0",
      commitSha: "abc123",
    )],
  )

proc makeOciVersion(signedByUrl: string): Version =
  Version(
    version:     "1.0.0",
    contentHash: "sha256:aabbcc",
    attestation: "author-signed",
    signedBy:    signedByUrl,
    publishedAt: "2026-01-01T00:00:00Z",
    provenances: @[Provenance(
      kind:       pkOci,
      registry:   "ghcr.io",
      repository: "owner/repo",
      digest:     "sha256:deadbeef",
    )],
  )

proc makeEmptyVersion(): Version =
  Version(
    version:     "1.0.0",
    contentHash: "sha256:aabbcc",
    attestation: "milpa-vendored",
    signedBy:    "",
    publishedAt: "2026-01-01T00:00:00Z",
    provenances: @[],
  )

proc makeBothVersion(gitUrl, signedByUrl: string): Version =
  Version(
    version:     "1.0.0",
    contentHash: "sha256:aabbcc",
    attestation: "author-signed",
    signedBy:    signedByUrl,
    publishedAt: "2026-01-01T00:00:00Z",
    provenances: @[Provenance(
      kind:      pkGit,
      url:       gitUrl,
      gitRef:    "v1.0.0",
      commitSha: "abc123",
    )],
  )

# ---------------------------------------------------------------------------
# Core behaviours (P0.3)
# ---------------------------------------------------------------------------

suite "deriveVersionNamespace — pkGit provenance":
  test "pkGit url https://github.com/greenm01/nimkdl derives github.com/greenm01":
    let v = makeGitVersion("https://github.com/greenm01/nimkdl")
    let r = deriveVersionNamespace(v)
    check r.isOk
    check r.get == "github.com/greenm01"

suite "deriveVersionNamespace — pkOci-only with signedBy":
  test "pkOci-only + GH-Actions OIDC SAN derives github.com/owner":
    let v = makeOciVersion(
      "https://github.com/owner/repo/.github/workflows/publish.yaml@refs/heads/main"
    )
    let r = deriveVersionNamespace(v)
    check r.isOk
    check r.get == "github.com/owner"

suite "deriveVersionNamespace — no pkGit and no signedBy":
  test "empty provenances + empty signedBy returns err(derrUnparseable)":
    let v = makeEmptyVersion()
    let r = deriveVersionNamespace(v)
    check r.isErr
    check r.error == derrUnparseable

suite "deriveVersionNamespace — pkGit takes priority over signedBy":
  test "pkGit provenance is preferred over non-empty signedBy":
    let v = makeBothVersion(
      "https://github.com/greenm01/nimkdl",
      "https://github.com/owner/repo/.github/workflows/publish.yaml@refs/heads/main",
    )
    let r = deriveVersionNamespace(v)
    check r.isOk
    check r.get == "github.com/greenm01"   # pkGit wins, NOT signedBy

# ---------------------------------------------------------------------------
# Vendored-anchor invariant (falsifiable loop over representative inputs)
# ---------------------------------------------------------------------------
# No property-testing harness in this repo. Written as an explicit loop over
# a representative set of well-formed VendoredEntry values (varied hosts/
# orgs: github, gitlab, sr.ht, codeberg, bitbucket, SSH-form, percent-encoded)
# built via buildVendoredEntry, asserting that:
#   1. entry.version.provenances[0].kind == pkGit
#   2. deriveVersionNamespace(entry.version) ==
#      deriveNamespace(entry.package.upstream).map(namespaceString)
# ---------------------------------------------------------------------------

suite "deriveVersionNamespace — vendored-anchor invariant":
  test "vendored entries: pkGit anchor matches upstream namespace across forge variants":
    let cases: seq[tuple[url, name: string]] = @[
      ("https://github.com/greenm01/nimkdl",               "nimkdl"),
      ("https://github.com/coreyleavitt/milpa",             "milpa"),
      ("https://gitlab.com/nim-lang/nimble",                "nimble"),
      ("https://codeberg.org/SomeUser/mylib",               "mylib"),
      ("https://git.sr.ht/~SomeUser/repo",                  "repo"),
      ("https://bitbucket.org/MyOrg/proj",                  "proj"),
      ("git@github.com:acme/tool.git",                      "tool"),
      ("https://github.com/%6Frg/encoded",                  "encoded"),
    ]

    let dummySelection = TagSelection(tag: "v1.0.0", version: "1.0.0")

    for (url, name) in cases:
      let pkg = UpstreamPackage(name: name, url: url)
      let entryResult = buildVendoredEntry(pkg, dummySelection,
          "sha256:deadbeef", "abc123", "2026-01-01T00:00:00Z")
      check entryResult.isOk
      let entry = entryResult.get

      # Invariant 1: first provenance is pkGit
      check entry.version.provenances.len > 0
      check entry.version.provenances[0].kind == pkGit

      # Invariant 2: deriveVersionNamespace == deriveNamespace(upstream)
      let fromVersion  = deriveVersionNamespace(entry.version)
      let fromUpstream = deriveNamespace(entry.package.upstream).map(
        proc(f: ForgeRef): string = namespaceString(f)
      )
      check fromVersion.isOk
      check fromUpstream.isOk
      check fromVersion.get == fromUpstream.get
