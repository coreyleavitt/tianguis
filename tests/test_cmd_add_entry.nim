## CLI tests for `tianguis add-entry` — the subcommand the commit-entry.yaml
## workflow runs after dispatch + cosign verify. Pulls + hashes the OCI
## artifact, merges into index.kdl, writes back.

import std/[unittest, options, os, strutils, tempfiles]
import tianguis/[model, kdl_io]
import tianguis/vendor/[addentry]

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-add-entry-", "")
  try:
    body
  finally:
    removeDir(name)

# Fake driver canned to return a known content_hash + commit_sha for a given
# OCI ref. Lets us assert the merge result without doing real I/O.
type FakeAddDriver = ref object of AddEntryDriver
  expectedRef:  string
  contentHash:  string
  commitSha:    string

method pullAndHash*(d: FakeAddDriver, ociRef: string): tuple[hash, sha: string] =
  if ociRef != d.expectedRef:
    raise newException(ValueError, "FakeAddDriver received unexpected ref: " & ociRef)
  (d.contentHash, d.commitSha)

# Driver that always fails pull — used to confirm exit code 3 on I/O failure.
type FailingPullDriver = ref object of AddEntryDriver

method pullAndHash*(d: FailingPullDriver, ociRef: string): tuple[hash, sha: string] =
  raise newException(IOError, "simulated oras pull failure")

suite "cli add-entry":
  # ---------------------------------------------------------------------------
  # P2.1 — valid full GH Actions SAN derives namespace; no --namespace field
  # ---------------------------------------------------------------------------

  test "valid GH Actions SAN derives namespace to github.com/owner, no namespace arg":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")

      let driver = FakeAddDriver(
        expectedRef:  "ghcr.io/coreyleavitt/sample@sha256:abc123",
        contentHash:  "sha256:abcdef",
        commitSha:    "deadbeef1234567",
      )

      let san = "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0"
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name:        "sample",
          version:     "v1.0.0",
          ociRef:      "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream:    "https://github.com/coreyleavitt/sample",
          signedBy:    san,
          publishedAt: "2026-06-01T12:00:00Z",
        ),
        driver = driver,
      )
      check code == 0

      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      let idx = parsed.get
      check idx.packages.len == 1
      let pkg = idx.packages[0]
      check pkg.name == "sample"
      # namespace derived from SAN: github.com/coreyleavitt
      check pkg.namespace == "github.com/coreyleavitt"
      check pkg.upstream == "https://github.com/coreyleavitt/sample"
      check pkg.versions.len == 1
      let v = pkg.versions[0]
      check v.version == "1.0.0"
      check v.contentHash == "sha256:abcdef"
      check v.attestation == "author-signed"
      # signedBy stores the verbatim SAN
      check v.signedBy == san
      check v.publishedAt == "2026-06-01T12:00:00Z"

  # ---------------------------------------------------------------------------
  # P2.1 — underivable signedBy → exit 4, index unchanged, alerts.kdl written
  # ---------------------------------------------------------------------------

  test "empty signedBy is underivable: exit 4, index unchanged, alerts.kdl written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name:     "sample",
          version:  "v1.0.0",
          ociRef:   "ghcr.io/x/sample@sha256:abc",
          upstream: "https://github.com/x/sample",
          signedBy: "",   # empty SAN — underivable
          publishedAt: "2026-06-01T12:00:00Z",
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 4
      check readFile(tmp / "index.kdl") == originalBytes
      # alerts.kdl should record the rejection
      check fileExists(tmp / "alerts.kdl")
      let alertsContent = readFile(tmp / "alerts.kdl")
      check "reject" in alertsContent
      check "namespace-underivable" in alertsContent

  test "non-github host SAN is underivable: exit 4, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      # A bare host with no org segment → derrNoOrg
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name:     "pkg",
          version:  "1.0.0",
          ociRef:   "ghcr.io/x/pkg@sha256:abc",
          upstream: "https://notgithub.com/pkg",
          signedBy: "https://notgithub.com",   # no org segment
          publishedAt: "2026-06-01T12:00:00Z",
        ),
        driver = FailingPullDriver(),
      )
      check code == 4
      check readFile(tmp / "index.kdl") == originalBytes
      let alertsContent = readFile(tmp / "alerts.kdl")
      check "namespace-underivable" in alertsContent
      check "notgithub.com" in alertsContent

  test "bare host-only SAN (no org) is underivable: exit 4, alerts.kdl written":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "pkg", version: "1.0.0",
          ociRef: "ghcr.io/x/pkg@sha256:abc",
          upstream: "https://github.com/x/pkg",
          signedBy: "https://github.com",   # no org in path
        ),
        driver = FailingPullDriver(),
      )
      check code == 4
      check readFile(tmp / "index.kdl") == originalBytes
      check fileExists(tmp / "alerts.kdl")

  test "underivable signedBy: OCI pull is NOT attempted (reject before network)":
    ## Prove via FailingPullDriver that derivation guard fires before pull I/O.
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "1.0.0",
          ociRef: "ghcr.io/x/sample@sha256:abc",
          upstream: "https://github.com/x/sample",
          signedBy: "",  # underivable
        ),
        driver = FailingPullDriver(),  # would raise if reached
      )
      # exit 4 = namespace-underivable (not exit 3 = pull failure)
      check code == 4

  test "alerts.kdl contains signed_by and reason on reject":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let badSan = "not-a-url"
      discard cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "p", version: "1.0.0",
          ociRef: "ghcr.io/x/p@sha256:abc",
          upstream: "https://github.com/x/p",
          signedBy: badSan,
        ),
        driver = FailingPullDriver(),
      )
      let alertsContent = readFile(tmp / "alerts.kdl")
      check badSan in alertsContent
      # reason is the DerivationError name
      check ("derrUnparseable" in alertsContent or "derrNoOrg" in alertsContent or
             "unparseable" in alertsContent or "no-org" in alertsContent)

  # ---------------------------------------------------------------------------
  # P2.1 — happy path still works: publishedAt defaults to now
  # ---------------------------------------------------------------------------

  test "publishedAt defaults to now when not supplied":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/x/y@sha256:abc",
        contentHash: "sha256:zzz",
        commitSha:   "",
      )
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main",
          # publishedAt deliberately omitted
        ),
        driver = driver,
      )
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      let pa = parsed.get.packages[0].versions[0].publishedAt
      # ISO 8601 UTC shape: YYYY-MM-DDTHH:MM:SSZ
      check pa.len == 20
      check pa.endsWith("Z")
      check pa[4] == '-' and pa[7] == '-' and pa[10] == 'T'

  # ---------------------------------------------------------------------------
  # Durable Rekor reference — captured at publish, recorded on the version
  # ---------------------------------------------------------------------------

  test "rekor fields are recorded on the author-signed version":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/coreyleavitt/nkdl@sha256:01c9ee",
        contentHash: "sha256:dd907474",
        commitSha:   "",
      )
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "nkdl", version: "v0.1.0",
          ociRef: "ghcr.io/coreyleavitt/nkdl@sha256:01c9ee",
          upstream: "https://github.com/coreyleavitt/nkdl",
          signedBy: "https://github.com/coreyleavitt/tianguis/.github/workflows/publish.yaml@refs/heads/main",
          publishedAt: "2026-06-08T01:18:24Z",
          rekorUuid: "108e9186e8c5677abce5a62d285437741218f878474a02d9a4dac01dc12e39b979336e712890d636",
          rekorLogIndex: "1753541583",
          rekorIntegratedTime: "1780881469",
        ),
        driver = driver,
      )
      check code == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      let rk = parsed.get.packages[0].versions[0].rekor
      check rk.isSome
      check rk.get.uuid == "108e9186e8c5677abce5a62d285437741218f878474a02d9a4dac01dc12e39b979336e712890d636"
      check rk.get.logIndex == "1753541583"
      check rk.get.integratedTime == "1780881469"

  test "no rekor flags → no rekor block on the version":
    ## A publish where the workflow failed to capture any Rekor field must not
    ## synthesize a hollow block; the version simply carries no pointer.
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/x/y@sha256:abc",
        contentHash: "sha256:zzz", commitSha: "",
      )
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main",
          # rekor* all empty
        ),
        driver = driver,
      )
      check code == 0
      check "rekor" notin readFile(tmp / "index.kdl")
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.packages[0].versions[0].rekor.isNone

  # ---------------------------------------------------------------------------
  # Pull failure still returns exit 3 (unrelated to namespace derivation)
  # ---------------------------------------------------------------------------

  test "pull failure refuses to commit (exit 3)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          # valid SAN — guard passes, then pull fails
          signedBy: "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main",
        ),
        driver = FailingPullDriver(),
      )
      check code == 3
      check readFile(tmp / "index.kdl") == originalBytes

# ---------------------------------------------------------------------------
# T1 — isValidPackageName: unsafe name rejection (path-traversal + DoS guard)
# ---------------------------------------------------------------------------
# These tests are the regression pin for the fix that tightened the validator
# to match milpa's is_safe_name semantics (single source of truth across impls).
# Names that pass the charset but are structurally unsafe MUST be rejected by
# the validator and cause cmdAddEntry to return exit 4 with no mutation.

suite "isValidPackageName — unsafe names":
  let validSan = "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main"

  test "empty name is invalid":
    check not isValidPackageName("")

  test "double-dot component (..) is invalid — registry-wide DoS vector":
    # A name of exactly `..` passes the charset but would make index.kdl
    # unparseable by milpa's _validate_safe_name, causing a registry-wide DoS.
    check not isValidPackageName("..")

  test "single-dot (.) is invalid — not a meaningful package name":
    check not isValidPackageName(".")

  test "leading-dot name (.git) is invalid":
    check not isValidPackageName(".git")

  test "name containing .. sequence (a..b) is invalid":
    check not isValidPackageName("a..b")

  test "name containing forward-slash is invalid (charset-rejected)":
    # '/' is not in the allowlist charset, so already rejected — verify.
    check not isValidPackageName("a/b")

  test "name containing backslash is invalid (charset-rejected)":
    check not isValidPackageName("a\\b")

  test "valid name foo-bar_1.2 passes":
    check isValidPackageName("foo-bar_1.2")

  test "valid name nim-chronos passes":
    check isValidPackageName("nim-chronos")

  # Integration: ensure cmdAddEntry returns exit 4 + no mutation for bad names.
  test "cmdAddEntry with name=.. returns exit 4, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let original = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "..", version: "1.0.0",
          ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: validSan,
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 4
      check readFile(tmp / "index.kdl") == original

  test "cmdAddEntry with name=.git returns exit 4, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let original = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: ".git", version: "1.0.0",
          ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: validSan,
        ),
        driver = FailingPullDriver(),
      )
      check code == 4
      check readFile(tmp / "index.kdl") == original
