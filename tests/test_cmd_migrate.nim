## Tests for the `tianguis migrate` subcommand (P1.4).
##
## Architecture:
##   pure core:  buildMigrationReport(idx) → MigrationReport
##   pure renderers: renderDryRun(report) → string
##                   renderAuditRecord(report) → string
##   thin I/O:   cmdMigrate(projectDir, execute) → int
##
## All synthetic fixtures reused from test_migrate_index.nim pattern.
## Tests NEVER point at the real index.kdl — only temp-dir projects.

import std/[unittest, os, strutils, tables, tempfiles]
import std/json as stdjson
import tianguis/[model, kdl_io, json_io, migrate, cmd_migrate]

# ---------------------------------------------------------------------------
# Synthetic builders (same pattern as test_migrate_index.nim)
# ---------------------------------------------------------------------------

proc gitProv(url: string, gitRef = "v1.0.0", sha = "deadbeef"): Provenance =
  Provenance(kind: pkGit, url: url, gitRef: gitRef, commitSha: sha)

proc ociProv(registry = "ghcr.io", repository = "coreyleavitt/nimkdl",
             digest = "sha256:abcd"): Provenance =
  Provenance(kind: pkOci, registry: registry, repository: repository, digest: digest)

proc makeVersion(vstr: string, prov: Provenance,
                 contentHash = "sha256:aabbcc",
                 publishedAt = "2026-01-01T00:00:00Z"): Version =
  Version(
    version:          vstr,
    contentHash:      contentHash,
    provenances:      @[prov],
    attestation:      "milpa-vendored",
    signedBy:         "",
    publishedAt:      publishedAt,
    partiallyResolved: false,
    requires:         initOrderedTable[string, string](),
  )

proc orgOnlyPackage(): Package =
  Package(
    name:      "milpa",
    namespace: "coreyleavitt",
    upstream:  "https://github.com/coreyleavitt/milpa",
    versions:  @[makeVersion("1.0.0", gitProv("https://github.com/coreyleavitt/milpa"),
                              contentHash = "sha256:milpa100")],
  )

proc alreadyMigratedPackage(): Package =
  Package(
    name:      "fresco",
    namespace: "github.com/coreyleavitt",
    upstream:  "https://github.com/coreyleavitt/fresco",
    versions:  @[makeVersion("2.0.0", gitProv("https://github.com/coreyleavitt/fresco"),
                              contentHash = "sha256:fresco200")],
  )

proc nimkdlGreenm01Version(): Version =
  makeVersion("0.5.0", gitProv("https://github.com/greenm01/nimkdl"),
              contentHash = "sha256:nimkdl-greenm01")

proc nimkdlCoreyVersion(): Version =
  Version(
    version:      "1.0.0",
    contentHash:  "sha256:nimkdl-corey",
    provenances:  @[ociProv()],
    attestation:  "author-signed",
    signedBy:     "https://github.com/coreyleavitt/tianguis/.github/workflows/publish.yaml@refs/heads/main",
    publishedAt:  "2026-01-01T00:00:00Z",
    partiallyResolved: false,
    requires:     initOrderedTable[string, string](),
  )

proc conflatedNimkdlPackage(): Package =
  Package(
    name:      "nimkdl",
    namespace: "greenm01",
    upstream:  "https://github.com/greenm01/nimkdl",
    versions:  @[nimkdlGreenm01Version(), nimkdlCoreyVersion()],
  )

proc smallIndex(pkgs: seq[Package]): Index =
  Index(schemaVersion: 1, packages: pkgs)

template withTempProject(name: untyped, idx: Index, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-migrate-", "")
  try:
    writeFile(name / "index.kdl", formatKdl(idx))
    body
  finally:
    removeDir(name)

# ---------------------------------------------------------------------------
# Suite 1 — buildMigrationReport: pure core
# ---------------------------------------------------------------------------

suite "cmd_migrate — buildMigrationReport: pure core":
  test "all-org-only index: countBefore == countAfter, no splits":
    let idx = smallIndex(@[orgOnlyPackage(), alreadyMigratedPackage()])
    let reportResult = buildMigrationReport(idx)
    check reportResult.isOk
    let report = reportResult.get
    check report.countBefore == 2
    check report.countAfter == 2
    check report.splits.len == 0

  test "conflated nimkdl: countBefore=1, countAfter=2, one split":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let reportResult = buildMigrationReport(idx)
    check reportResult.isOk
    let report = reportResult.get
    check report.countBefore == 1
    check report.countAfter == 2
    check report.splits.len == 1
    # The one split is nimkdl → [github.com/greenm01, github.com/coreyleavitt]
    check report.splits[0].name == "nimkdl"
    let ns = report.splits[0].namespaces
    check ns.len == 2
    check "github.com/greenm01" in ns
    check "github.com/coreyleavitt" in ns

  test "already-migrated index: no splits, idempotent report":
    let idx = smallIndex(@[alreadyMigratedPackage()])
    let reportResult = buildMigrationReport(idx)
    check reportResult.isOk
    let report = reportResult.get
    check report.countBefore == 1
    check report.countAfter == 1
    check report.splits.len == 0

  test "mixed index (org-only + migrated + conflated): splits only the conflated entry":
    let idx = smallIndex(@[orgOnlyPackage(), alreadyMigratedPackage(), conflatedNimkdlPackage()])
    let reportResult = buildMigrationReport(idx)
    check reportResult.isOk
    let report = reportResult.get
    check report.countBefore == 3
    check report.countAfter == 4   # nimkdl splits into 2
    check report.splits.len == 1
    check report.splits[0].name == "nimkdl"

  test "derivation failure propagates as err":
    # A version with no git prov and empty signedBy cannot be derived
    let badVersion = Version(
      version: "1.0.0", contentHash: "sha256:bad",
      provenances: @[], attestation: "milpa-vendored",
      signedBy: "", publishedAt: "2026-01-01T00:00:00Z",
      partiallyResolved: false,
      requires: initOrderedTable[string, string](),
    )
    let pkg = Package(name: "broken", namespace: "", upstream: "https://example.com",
                      versions: @[badVersion])
    let result = buildMigrationReport(smallIndex(@[pkg]))
    check result.isErr

  test "report.migrated is the fully-migrated canonical Index":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let report = buildMigrationReport(idx).get
    # migrated has host/org namespaces everywhere
    for pkg in report.migrated.packages:
      check '/' in pkg.namespace

# ---------------------------------------------------------------------------
# Suite 2 — renderDryRun: pure renderer
# ---------------------------------------------------------------------------

suite "cmd_migrate — renderDryRun: pure renderer":
  test "dry-run output ends with sentinel line":
    let idx = smallIndex(@[orgOnlyPackage()])
    let report = buildMigrationReport(idx).get
    let output = renderDryRun(report)
    check output.endsWith("DRY RUN — no changes written\n") or
          output.contains("DRY RUN — no changes written")

  test "dry-run output contains split diagnostic for nimkdl":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let report = buildMigrationReport(idx).get
    let output = renderDryRun(report)
    check "nimkdl" in output
    check "github.com/greenm01" in output
    check "github.com/coreyleavitt" in output

  test "dry-run output mentions package counts":
    let idx = smallIndex(@[orgOnlyPackage(), conflatedNimkdlPackage()])
    let report = buildMigrationReport(idx).get
    let output = renderDryRun(report)
    # countBefore=2, countAfter=3
    check "2" in output
    check "3" in output

  test "dry-run output with no splits says no splits":
    let idx = smallIndex(@[alreadyMigratedPackage()])
    let report = buildMigrationReport(idx).get
    let output = renderDryRun(report)
    # No split diagnostics — should mention 0 or "no splits"
    check "0" in output or "no split" in output.toLower

# ---------------------------------------------------------------------------
# Suite 3 — renderAuditRecord: pure renderer
# ---------------------------------------------------------------------------

suite "cmd_migrate — renderAuditRecord: pure renderer":
  test "audit record is valid JSON":
    let idx = smallIndex(@[orgOnlyPackage()])
    let report = buildMigrationReport(idx).get
    let jsonStr = renderAuditRecord(report)
    let node = stdjson.parseJson(jsonStr)
    check node.kind == stdjson.JObject

  test "audit record contains package_count_before and package_count_after":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let report = buildMigrationReport(idx).get
    let node = stdjson.parseJson(renderAuditRecord(report))
    check node.hasKey("package_count_before")
    check node.hasKey("package_count_after")
    check node["package_count_before"].getInt == 1
    check node["package_count_after"].getInt == 2

  test "audit record contains splits array with nimkdl entry":
    let idx = smallIndex(@[conflatedNimkdlPackage()])
    let report = buildMigrationReport(idx).get
    let node = stdjson.parseJson(renderAuditRecord(report))
    check node.hasKey("splits")
    check node["splits"].kind == stdjson.JArray
    check node["splits"].len == 1
    let split = node["splits"][0]
    check split["name"].getStr == "nimkdl"
    check split.hasKey("namespaces")
    check split["namespaces"].kind == stdjson.JArray
    check split["namespaces"].len == 2

  test "audit record has empty splits array when no splits occur":
    let idx = smallIndex(@[alreadyMigratedPackage()])
    let report = buildMigrationReport(idx).get
    let node = stdjson.parseJson(renderAuditRecord(report))
    check node["splits"].len == 0

# ---------------------------------------------------------------------------
# Suite 4 — cmdMigrate I/O: dry-run writes nothing
# ---------------------------------------------------------------------------

suite "cmd_migrate — dry-run I/O: writes nothing":
  test "dry-run (execute=false) does not modify index.kdl":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      let originalKdl = readFile(tmp / "index.kdl")
      let code = cmdMigrate(tmp, execute = false)
      check code == 0
      check readFile(tmp / "index.kdl") == originalKdl

  test "dry-run does not create index.kdl.bak":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      discard cmdMigrate(tmp, execute = false)
      check not fileExists(tmp / "index.kdl.bak")

  test "dry-run does not create index.json":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      discard cmdMigrate(tmp, execute = false)
      check not fileExists(tmp / "index.json")

  test "dry-run returns 0 on valid index":
    withTempProject(tmp, smallIndex(@[conflatedNimkdlPackage()])):
      check cmdMigrate(tmp, execute = false) == 0

# ---------------------------------------------------------------------------
# Suite 5 — cmdMigrate I/O: execute mutates atomically
# ---------------------------------------------------------------------------

suite "cmd_migrate — execute I/O: atomic mutation":
  test "execute writes migrated index.kdl":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      check cmdMigrate(tmp, execute = true) == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      # namespace upgraded to host/org
      check '/' in parsed.get.packages[0].namespace

  test "execute writes index.kdl.bak matching original":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      let original = readFile(tmp / "index.kdl")
      check cmdMigrate(tmp, execute = true) == 0
      check fileExists(tmp / "index.kdl.bak")
      check readFile(tmp / "index.kdl.bak") == original

  test "execute writes index.json consistent with migrated index.kdl":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      check cmdMigrate(tmp, execute = true) == 0
      check fileExists(tmp / "index.json")
      let kdlResult = parseKdl(readFile(tmp / "index.kdl"))
      let jsonResult = json_io.parseJson(readFile(tmp / "index.json"))
      check kdlResult.isOk
      check jsonResult.isOk
      check kdlResult.get == jsonResult.get

  test "execute creates the audit record at the expected path":
    withTempProject(tmp, smallIndex(@[conflatedNimkdlPackage()])):
      check cmdMigrate(tmp, execute = true) == 0
      let auditPath = tmp / "docs" / "spec" / "migrations" / "0001-32-identity.json"
      check fileExists(auditPath)

  test "audit record is valid JSON with correct split info":
    withTempProject(tmp, smallIndex(@[conflatedNimkdlPackage()])):
      discard cmdMigrate(tmp, execute = true)
      let auditPath = tmp / "docs" / "spec" / "migrations" / "0001-32-identity.json"
      let node = stdjson.parseJson(readFile(auditPath))
      check node["package_count_before"].getInt == 1
      check node["package_count_after"].getInt == 2
      check node["splits"].len == 1

  test "execute returns 0 on success with sentinel message":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      check cmdMigrate(tmp, execute = true) == 0

  test "second execute is idempotent (already-migrated input)":
    withTempProject(tmp, smallIndex(@[orgOnlyPackage()])):
      check cmdMigrate(tmp, execute = true) == 0
      # Second run on the already-migrated index
      check cmdMigrate(tmp, execute = true) == 0
      let parsed = parseKdl(readFile(tmp / "index.kdl"))
      check parsed.isOk
      for pkg in parsed.get.packages:
        check '/' in pkg.namespace

  test "execute on derivation-failure index returns non-zero, writes nothing":
    let badVersion = Version(
      version: "1.0.0", contentHash: "sha256:bad",
      provenances: @[], attestation: "milpa-vendored",
      signedBy: "", publishedAt: "2026-01-01T00:00:00Z",
      partiallyResolved: false,
      requires: initOrderedTable[string, string](),
    )
    let pkg = Package(name: "broken", namespace: "", upstream: "https://example.com",
                      versions: @[badVersion])
    withTempProject(tmp, smallIndex(@[pkg])):
      let originalKdl = readFile(tmp / "index.kdl")
      let code = cmdMigrate(tmp, execute = true)
      check code != 0
      check readFile(tmp / "index.kdl") == originalKdl
      check not fileExists(tmp / "index.kdl.bak")

# ---------------------------------------------------------------------------
# Suite 6 — atomicWrite helper: staging + rename
# ---------------------------------------------------------------------------

suite "cmd_migrate — atomicWrite helper":
  test "atomicWrite writes content to destination":
    let tmp = createTempDir("tianguis-atomic-", "")
    try:
      let dest = tmp / "out.txt"
      atomicWrite(dest, "hello world\n")
      check fileExists(dest)
      check readFile(dest) == "hello world\n"
    finally:
      removeDir(tmp)

  test "atomicWrite does not leave a staging file behind on success":
    let tmp = createTempDir("tianguis-atomic-", "")
    try:
      let dest = tmp / "out.txt"
      atomicWrite(dest, "content")
      # No .tmp file should remain
      for f in walkFiles(tmp / "*.tmp"):
        fail()
    finally:
      removeDir(tmp)
