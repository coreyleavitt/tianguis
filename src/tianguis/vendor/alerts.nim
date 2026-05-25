## Alert log shape for the vendoring bot.
##
## alerts.kdl is the public, append-only record of every drift event
## (and, eventually, vendoring failures + dispatch rejections) the bot
## encounters. Humans triage; the bot never mutates entries it has
## already logged.
##
## Schema:
##   drift "<package>" {
##       version       "<v>"
##       detected_at   "<ISO 8601 UTC>"
##       existing_hash "<sha256:...>"
##       new_hash      "<sha256:...>"
##   }

import ./merge

proc formatDriftAlert*(alert: DriftAlert, detectedAt: string): string =
  result.add("drift \"" & alert.packageName & "\" {\n")
  result.add("    version       \"" & alert.version & "\"\n")
  result.add("    detected_at   \"" & detectedAt & "\"\n")
  result.add("    existing_hash \"" & alert.existingHash & "\"\n")
  result.add("    new_hash      \"" & alert.newHash & "\"\n")
  result.add("}\n")

proc appendAlert*(existing: string, alert: DriftAlert, detectedAt: string): string =
  ## Returns `existing` with `alert` appended. Append-only — never
  ## mutates prior entries.
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatDriftAlert(alert, detectedAt))
