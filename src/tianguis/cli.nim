## tianguis CLI: thin orchestration over the kdl_io / json_io modules.
##
## `tianguis project` is the canonical command for keeping the JSON
## projection in sync with the KDL source-of-truth. CI invokes it with
## `--check` to fail builds on drift; humans run it without flags to
## regenerate index.json after editing index.kdl.

import std/[os, times]
import ./kdl_io
import ./json_io
import ./vendor/[denylist, orchestrate, driver]

proc cmdProject*(projectDir: string, check: bool): int =
  ## Read <projectDir>/index.kdl. If `check`, compare the parsed Index
  ## to the parsed <projectDir>/index.json and exit non-zero on any
  ## semantic difference. Otherwise regenerate index.json from the KDL
  ## source.
  ##
  ## Exit codes:
  ##   0 — success (parity confirmed, or regeneration completed)
  ##   1 — index.kdl missing or malformed
  ##   2 — drift detected (check mode) or parse error on index.json
  let kdlPath = projectDir / "index.kdl"
  let jsonPath = projectDir / "index.json"

  if not fileExists(kdlPath):
    stderr.writeLine("tianguis: " & kdlPath & " not found")
    return 1

  let kdlText = readFile(kdlPath)
  let kdlResult = parseKdl(kdlText)
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & kdlPath & ": " & $e.code & ": " & e.message)
    return 1

  if check:
    if not fileExists(jsonPath):
      stderr.writeLine("tianguis: " & jsonPath & " missing (run `tianguis project` to regenerate)")
      return 2
    let jsonText = readFile(jsonPath)
    let jsonResult = parseJson(jsonText)
    if jsonResult.isErr:
      let e = jsonResult.getErr
      stderr.writeLine("tianguis: " & jsonPath & ": " & $e.code & ": " & e.message)
      return 2
    if kdlResult.get != jsonResult.get:
      stderr.writeLine(
        "tianguis: index.kdl and index.json disagree (run `tianguis project` to regenerate)"
      )
      return 2
    return 0
  else:
    writeFile(jsonPath, formatJson(kdlResult.get))
    return 0

proc cmdVendor*(projectDir: string): int =
  ## Run one vendoring pass: fetch nim-lang/packages.json, merge new
  ## entries into index.kdl, append drift alerts to alerts.kdl.
  ## Exit codes:
  ##   0 — pass completed (entries may or may not have been added; check
  ##       git diff)
  ##   1 — fatal I/O failure (network, malformed manifest, etc.)
  let indexPath    = projectDir / "index.kdl"
  let denylistPath = projectDir / "denylist.kdl"
  let alertsPath   = projectDir / "alerts.kdl"

  if not fileExists(indexPath):
    stderr.writeLine("tianguis: " & indexPath & " not found")
    return 1

  let kdlResult = parseKdl(readFile(indexPath))
  if kdlResult.isErr:
    let e = kdlResult.getErr
    stderr.writeLine("tianguis: " & indexPath & ": " & $e.code & ": " & e.message)
    return 1

  let dl = if fileExists(denylistPath):
             parseDenylist(readFile(denylistPath))
           else: Denylist()
  let existingAlerts = if fileExists(alertsPath):
                         readFile(alertsPath)
                       else: ""

  let driver = newRealDriver()
  let res = try:
    runVendor(
      driver,
      initialIndex  = kdlResult.get,
      denylist      = dl,
      initialAlerts = existingAlerts,
      nowIso        = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    )
  except IOError as e:
    stderr.writeLine("tianguis: vendor I/O error: " & e.msg)
    return 1

  writeFile(indexPath, formatKdl(res.index))
  if res.alerts != existingAlerts:
    writeFile(alertsPath, res.alerts)
  for skipped in res.skipped:
    stderr.writeLine("tianguis: skipped denylisted package " & skipped)
  return 0
