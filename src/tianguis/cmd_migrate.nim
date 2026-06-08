## Subcommand: `tianguis migrate` — P1.4 one-shot namespace migration.
##
## {.deprecated: "one-time #32 migration".}
##
## Architecture:
##   Pure core:  buildMigrationReport(idx) → Result[MigrationReport, MigrationHalt]
##   Pure renderers:
##     renderDryRun(report) → string   (human diff text, no I/O)
##     renderAuditRecord(report) → string  (machine-readable JSON record)
##   Thin I/O:   cmdMigrate(projectDir, execute) → int
##
## UX safety: --dry-run is the default (execute=false). Mutation requires
## explicit --execute. The {.deprecated.} pragma emits a COMPILE-TIME warning
## (invisible to operators at runtime); make the safety contract runtime-explicit
## by always printing a stderr notice in dry-run mode.
##
## Atomicity: --execute writes staging files then renames into place, covering
## BOTH index.kdl AND index.json. A crash between renames is recovered by:
##   git revert (reverts KDL) + re-run `tianguis project` (regenerates JSON).
## Pre-run index.kdl → index.kdl.bak as a local (non-committed) recovery aid.
##
## Exit codes:
##   0 — success (dry-run printed diff, or execute completed)
##   1 — index.kdl missing or malformed
##   2 — migrateIndex returned MigrationHalt (abort, no mutation)

{.deprecated: "one-time #32 migration".}

import std/[os, json, strutils, sequtils, algorithm, tables]
import nkdl
import ./model
import ./kdl_io
import ./json_io
import ./migrate
import ./fileutil

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  SplitEntry* = tuple[name: string, namespaces: seq[string]]

  MigrationReport* = object
    countBefore*: int
    countAfter*:  int
    splits*:      seq[SplitEntry]
    migrated*:    Index

# ---------------------------------------------------------------------------
# Pure core
# ---------------------------------------------------------------------------

proc buildMigrationReport*(idx: Index): Result[MigrationReport, MigrationHalt] =
  ## Run migrateIndex and compute the MigrationReport.
  ## Pure — no I/O.
  let migrateResult = migrateIndex(idx)
  if migrateResult.isErr:
    return err[MigrationReport, MigrationHalt](migrateResult.getErr)

  let migrated = migrateResult.get

  # Compute splits: find names where 2+ distinct namespaces appear in output
  # that originated from a single input package name.
  var inputNames: seq[string] = @[]
  for pkg in idx.packages:
    inputNames.add(pkg.name)

  # For each name in input, collect the distinct output namespaces
  var nameToNamespaces = initOrderedTable[string, seq[string]]()
  for pkg in migrated.packages:
    if pkg.name in inputNames:
      if pkg.name notin nameToNamespaces:
        nameToNamespaces[pkg.name] = @[]
      if pkg.namespace notin nameToNamespaces[pkg.name]:
        nameToNamespaces[pkg.name].add(pkg.namespace)

  var splits: seq[SplitEntry] = @[]
  for name, nsList in nameToNamespaces.pairs:
    # Count how many input packages had this name
    let inputCount = inputNames.count(name)
    if nsList.len > inputCount:
      # More output namespaces than input packages for this name — a split occurred
      splits.add((name: name, namespaces: sorted(nsList)))

  ok[MigrationReport, MigrationHalt](MigrationReport(
    countBefore: idx.packages.len,
    countAfter:  migrated.packages.len,
    splits:      splits,
    migrated:    migrated,
  ))

# ---------------------------------------------------------------------------
# Pure renderers
# ---------------------------------------------------------------------------

proc renderDryRun*(report: MigrationReport): string =
  ## Render the full dry-run diff to a string.
  ## Caller is responsible for printing to stdout.
  var lines: seq[string] = @[]
  lines.add("tianguis migrate — dry run")
  lines.add("  packages before: " & $report.countBefore)
  lines.add("  packages after:  " & $report.countAfter)
  if report.splits.len == 0:
    lines.add("  splits: 0 (no package required splitting)")
  else:
    lines.add("  splits: " & $report.splits.len)
    for s in report.splits:
      lines.add("    " & s.name & " → [" & s.namespaces.join(", ") & "]")
  lines.add("")
  lines.add("DRY RUN — no changes written")
  result = lines.join("\n") & "\n"

proc renderAuditRecord*(report: MigrationReport): string =
  ## Render a machine-readable JSON audit record.
  ## Captures: package counts, exact split set.
  let splitsNode = newJArray()
  for s in report.splits:
    let nsArray = newJArray()
    for ns in s.namespaces:
      nsArray.add(%ns)
    let entry = %*{
      "name":       s.name,
      "namespaces": nsArray,
    }
    splitsNode.add(entry)
  let node = %*{
    "migration":           "0001-32-identity",
    "package_count_before": report.countBefore,
    "package_count_after":  report.countAfter,
    "splits":              splitsNode,
  }
  result = $node

# ---------------------------------------------------------------------------
# Thin I/O
# ---------------------------------------------------------------------------

proc cmdMigrate*(projectDir: string, execute: bool): int
    {.deprecated: "one-time #32 migration".} =
  ## `tianguis migrate [--execute]`
  ##
  ## Default (execute=false): dry-run — print diff to stdout, write nothing.
  ## Also emits a one-line stderr notice.
  ##
  ## With execute=true: load index.kdl, migrate, write both index.kdl AND
  ## index.json atomically via staging files, write audit record, print
  ## "migration complete" to stdout.
  ##
  ## Exit codes:
  ##   0 — success
  ##   1 — index.kdl missing or malformed
  ##   2 — migrateIndex returned MigrationHalt (abort, no mutation)

  let kdlPath = projectDir / "index.kdl"
  if not fileExists(kdlPath):
    stderr.writeLine("tianguis: " & kdlPath & " not found")
    return 1

  let kdlText = readFile(kdlPath)
  let parseResult = parseKdl(kdlText)
  if parseResult.isErr:
    let e = parseResult.getErr
    stderr.writeLine("tianguis: " & kdlPath & ": " & $e.code & ": " & e.message)
    return 1

  let idx = parseResult.get

  let reportResult = buildMigrationReport(idx)
  if reportResult.isErr:
    let halt = reportResult.getErr
    case halt.kind
    of mhkDerivationFailed:
      stderr.writeLine("tianguis: migrate: derivation failed for " &
        halt.packageName & " v" & halt.version &
        " (" & halt.provenanceUrl & "): " & $halt.error)
    of mhkUnexpectedSplit:
      stderr.writeLine("tianguis: migrate: unexpected split — this is a bug")
    return 2

  let report = reportResult.get

  if not execute:
    # Dry-run: print diff, emit stderr notice, write nothing.
    echo renderDryRun(report)
    stderr.writeLine("one-time #32 migration; re-run with --execute to commit")
    return 0

  # Execute path: write everything atomically.
  # 1. Backup original KDL (local recovery aid, not committed).
  writeFile(kdlPath & ".bak", kdlText)

  # 2. Write migrated index.kdl via staging file.
  let newKdl = formatKdl(report.migrated)
  atomicWrite(kdlPath, newKdl)

  # 3. Write index.json via the SAME code path cmdProject uses (formatJson).
  let jsonPath = projectDir / "index.json"
  atomicWrite(jsonPath, formatJson(report.migrated))

  # 4. Write the migration audit record.
  let auditDir = projectDir / "docs" / "spec" / "migrations"
  createDir(auditDir)
  let auditPath = auditDir / "0001-32-identity.json"
  atomicWrite(auditPath, renderAuditRecord(report))

  echo "migration complete"
  return 0
