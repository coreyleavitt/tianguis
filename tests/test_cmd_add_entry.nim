## CLI tests for `tianguis add-entry` — the subcommand the commit-entry.yaml
## workflow runs after dispatch verifies a publish event. Takes the dispatched
## payload as args, verifies Rekor, pulls + hashes the OCI artifact, merges
## into index.kdl, writes back.

import std/[unittest, options, os, tables, tempfiles]
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

method verifyRekor*(d: FakeAddDriver, uuid: string, expected: AttestSubject): bool =
  # In tests we trust the injected verification — focus is on the merge logic.
  # Real driver will use sigstore-go via subprocess.
  true

method pullAndHash*(d: FakeAddDriver, ociRef: string): tuple[hash, sha: string] =
  if ociRef != d.expectedRef:
    raise newException(ValueError, "FakeAddDriver received unexpected ref: " & ociRef)
  (d.contentHash, d.commitSha)

# Subclass that rejects all Rekor verifications — used by cycle 10's
# refuse-to-commit test. Module-level so the method() definition is legal.
type RekorRejector = ref object of FakeAddDriver

method verifyRekor*(d: RekorRejector, uuid: string, expected: AttestSubject): bool =
  false

suite "cli add-entry":
  test "adds an author-signed entry to an empty index":
    withTempProject(tmp):
      # Bootstrap: empty index.kdl (schema_version 1 only).
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
          signedBy:    "https://github.com/coreyleavitt/sample",
          publishedAt: "2026-06-01T12:00:00Z",
          rekorUuid:   "test-uuid-xyz",
        ),
        driver = driver,
      )
      check code == 0
      # Author-supplied version normalizes v-prefix to bare numeric.
      # (The cycle 1 round-trip already verifies pkg.versions[0].version
      # against the value our test passes in.)

      # Verify index.kdl now has the author-signed entry.
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
      check v.signedBy == "https://github.com/coreyleavitt/sample"
      check v.publishedAt == "2026-06-01T12:00:00Z"
      # Provenance carries the OCI ref's commit_sha hint (where applicable;
      # for an OCI-published entry the commit_sha may be empty — covered later)

  test "rekor verification failure refuses to commit (exit 2)":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      let originalBytes = readFile(tmp / "index.kdl")

      let driver = RekorRejector(
        expectedRef:  "ghcr.io/x/y@sha256:abc",
        contentHash:  "sha256:never-written",
        commitSha:    "irrelevant",
      )
      let code = cmdAddEntry(
        projectDir = tmp,
        args = AddEntryArgs(
          name: "y", ociRef: "ghcr.io/x/y@sha256:abc",
          namespace: "x", upstream: "https://github.com/x/y",
          signedBy: "https://github.com/x/y",
          publishedAt: "2026-06-01T12:00:00Z",
          rekorUuid: "fake-uuid",
        ),
        driver = driver,
      )
      check code == 2
      # Index UNCHANGED — refusing to commit is the entire point.
      check readFile(tmp / "index.kdl") == originalBytes
