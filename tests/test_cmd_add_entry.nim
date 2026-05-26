## CLI tests for `tianguis add-entry` — the subcommand the commit-entry.yaml
## workflow runs after dispatch + cosign verify. Pulls + hashes the OCI
## artifact, merges into index.kdl, writes back.

import std/[unittest, options, os, strutils, tables, tempfiles]
import tianguis/[model, kdl_io]
import tianguis/vendor/[merge, addentry]

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
  test "adds an author-signed entry to an empty index":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")

      let driver = FakeAddDriver(
        expectedRef:  "ghcr.io/coreyleavitt/sample@sha256:abc123",
        contentHash:  "sha256:abcdef",
        commitSha:    "deadbeef1234567",
      )

      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name:        "sample",
          version:     "v1.0.0",
          ociRef:      "ghcr.io/coreyleavitt/sample@sha256:abc123",
          namespace:   "coreyleavitt",
          upstream:    "https://github.com/coreyleavitt/sample",
          signedBy:    "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
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
      check pkg.namespace == "coreyleavitt"
      check pkg.upstream == "https://github.com/coreyleavitt/sample"
      check pkg.versions.len == 1
      let v = pkg.versions[0]
      check v.version == "1.0.0"  # v-prefix stripped from passed "v1.0.0"
      check v.contentHash == "sha256:abcdef"
      check v.attestation == "author-signed"
      check v.signedBy == "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0"
      check v.publishedAt == "2026-06-01T12:00:00Z"

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
          namespace: "x", upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y",
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

  test "pull failure refuses to commit (exit 3)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", version: "1.0.0", ociRef: "ghcr.io/x/y@sha256:abc",
          namespace: "x", upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y",
        ),
        driver = FailingPullDriver(),
      )
      check code == 3
      check readFile(tmp / "index.kdl") == originalBytes
