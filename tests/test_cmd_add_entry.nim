## CLI tests for `tianguis add-entry` — the subcommand the commit-entry.yaml
## workflow runs after dispatch + cosign verify. Pulls + hashes the OCI
## artifact, merges into index.kdl, writes back.

import std/[unittest, options, os, strutils, tempfiles]
import tianguis/[model, kdl_io, attestation]
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

  # ---------------------------------------------------------------------------
  # S7a — --bundle-pin: sets Version.bundlePin so milpa's registry.py can
  # parse the 4th attestation sibling `bundle sha256="…"` off this entry.
  # ---------------------------------------------------------------------------

  test "--bundle-pin=<valid 64hex> sets bundlePin and emits bundle sha256 in KDL":
    ## Post-S8, --bundle-pin is atomic with --entry-statement (both-or-neither);
    ## this test now supplies a matching statement alongside the pin. See the
    ## dedicated both-or-neither tests below for the rejection cases.
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/x/y@sha256:abc",
        contentHash: "sha256:zzz", commitSha: "",
      )
      let pin = "a".repeat(64)
      let san = "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main"
      let stmtPath = tmp / "entry-statement.json"
      writeFile(stmtPath, buildEntryStatement(
        namespace = "github.com/x", name = "y", version = "1.0.0",
        contentHash = "sha256:zzz", attestationKind = "author-signed", signedBy = san,
      ))
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: san,
          publishedAt: "2026-06-01T12:00:00Z",
          bundlePin: pin,
          entryStatementPath: stmtPath,
        ),
        driver = driver,
      )
      check code == 0
      let kdlText = readFile(tmp / "index.kdl")
      check ("bundle sha256=\"" & pin & "\"") in kdlText
      let parsed = parseKdl(kdlText)
      check parsed.isOk
      let v = parsed.get.packages[0].versions[0]
      check v.bundlePin.isSome
      check v.bundlePin.get == pin

  test "--bundle-pin=<malformed> is rejected: exit 4, index unchanged":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y/.github/workflows/publish.yaml@refs/heads/main",
          publishedAt: "2026-06-01T12:00:00Z",
          bundlePin: "not-hex",
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 4
      check readFile(tmp / "index.kdl") == originalBytes

  test "no --bundle-pin supplied: bundlePin is none (regression guard)":
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
          publishedAt: "2026-06-01T12:00:00Z",
          # bundlePin deliberately omitted
        ),
        driver = driver,
      )
      check code == 0
      check "bundle" notin readFile(tmp / "index.kdl")
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      check parsed.get.packages[0].versions[0].bundlePin.isNone

  # ---------------------------------------------------------------------------
  # S8 — author-signed subject-binding: --entry-statement (must accompany
  # --bundle-pin) binds the CI-crypto-verified statement's claimed subject
  # to the content_hash add-entry itself just recomputed + the purl it
  # itself derives. THE SECURITY INVARIANT: never trust the author's claim.
  # ---------------------------------------------------------------------------

  test "--entry-statement matching digest+name + --bundle-pin: entry written with bundle sha256=":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let contentHash = "dag-sha256:" & "f".repeat(64)
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
        contentHash: contentHash,
        commitSha:   "",
      )
      let san = "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0"
      # namespace derived from san == "github.com/coreyleavitt" (per the
      # P2.1 test above); version normalizes "v1.0.0" -> "1.0.0".
      let stmt = buildEntryStatement(
        namespace = "github.com/coreyleavitt", name = "sample", version = "1.0.0",
        contentHash = contentHash, attestationKind = "author-signed", signedBy = san,
      )
      let stmtPath = tmp / "entry-statement.json"
      writeFile(stmtPath, stmt)
      let pin = "b".repeat(64)
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: san,
          publishedAt: "2026-06-01T12:00:00Z",
          bundlePin: pin,
          entryStatementPath: stmtPath,
        ),
        driver = driver,
      )
      check code == 0
      let kdlText = readFile(tmp / "index.kdl")
      check ("bundle sha256=\"" & pin & "\"") in kdlText
      let parsed = parseKdl(kdlText)
      check parsed.isOk
      check parsed.get.packages[0].versions[0].contentHash == contentHash

  test "--entry-statement digest != recomputed content_hash: reject (exit 5), no entry":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let realContentHash = "dag-sha256:" & "1".repeat(64)
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
        contentHash: realContentHash,
        commitSha:   "",
      )
      let san = "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0"
      # Statement binds a DIFFERENT digest than what tianguis actually pulled
      # and recomputed — the "malicious/stale author bundle" scenario.
      let stmt = buildEntryStatement(
        namespace = "github.com/coreyleavitt", name = "sample", version = "1.0.0",
        contentHash = "dag-sha256:" & "2".repeat(64),
        attestationKind = "author-signed", signedBy = san,
      )
      let stmtPath = tmp / "entry-statement.json"
      writeFile(stmtPath, stmt)
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: san,
          publishedAt: "2026-06-01T12:00:00Z",
          bundlePin: "b".repeat(64),
          entryStatementPath: stmtPath,
        ),
        driver = driver,
      )
      check code == 5
      check readFile(tmp / "index.kdl") == originalBytes

  test "--entry-statement name != derived purl: reject (exit 5), no entry":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let contentHash = "dag-sha256:" & "3".repeat(64)
      let driver = FakeAddDriver(
        expectedRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
        contentHash: contentHash,
        commitSha:   "",
      )
      let san = "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0"
      # Digest matches, but the statement was signed for a DIFFERENT package
      # (cross-package bundle replay: content_hash alone is name-independent).
      let stmt = buildEntryStatement(
        namespace = "github.com/coreyleavitt", name = "other-package", version = "1.0.0",
        contentHash = contentHash, attestationKind = "author-signed", signedBy = san,
      )
      let stmtPath = tmp / "entry-statement.json"
      writeFile(stmtPath, stmt)
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: san,
          publishedAt: "2026-06-01T12:00:00Z",
          bundlePin: "b".repeat(64),
          entryStatementPath: stmtPath,
        ),
        driver = driver,
      )
      check code == 5
      check readFile(tmp / "index.kdl") == originalBytes

  test "--entry-statement supplied without --bundle-pin: reject (exit 5), no entry, pull not attempted":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let stmtPath = tmp / "entry-statement.json"
      writeFile(stmtPath, buildEntryStatement(
        namespace = "github.com/coreyleavitt", name = "sample", version = "1.0.0",
        contentHash = "dag-sha256:" & "4".repeat(64),
        attestationKind = "author-signed", signedBy = "irrelevant",
      ))
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
          entryStatementPath: stmtPath,
          # bundlePin deliberately omitted
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 5
      check readFile(tmp / "index.kdl") == originalBytes

  test "--bundle-pin supplied without --entry-statement: reject (exit 5), no entry":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
          bundlePin: "b".repeat(64),
          # entryStatementPath deliberately omitted
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 5
      check readFile(tmp / "index.kdl") == originalBytes

  test "--entry-statement path does not exist: reject (exit 5), no entry":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "sample", version: "v1.0.0",
          ociRef: "ghcr.io/coreyleavitt/sample@sha256:abc123",
          upstream: "https://github.com/coreyleavitt/sample",
          signedBy: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
          bundlePin: "b".repeat(64),
          entryStatementPath: tmp / "does-not-exist.json",
        ),
        driver = FailingPullDriver(),  # must NOT be reached
      )
      check code == 5
      check readFile(tmp / "index.kdl") == originalBytes

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
