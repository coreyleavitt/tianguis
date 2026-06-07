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
##
##   identity-drift name="<package>" stored="<ns>" rederived="<ns>"
##
##   collision namespace="<ns>" name="<leaf>" existing-repo="<repo>" new-repo="<repo>"

import ./merge
import ../namespace

# ---------------------------------------------------------------------------
# Overloaded formatAlert — one per payload type (no sum-wrapper)
# ---------------------------------------------------------------------------

proc formatAlert*(alert: DriftAlert, detectedAt: string): string =
  ## Format a content-hash drift event as a KDL block.
  result.add("drift \"" & alert.packageName & "\" {\n")
  result.add("    version       \"" & alert.version & "\"\n")
  result.add("    detected_at   \"" & detectedAt & "\"\n")
  result.add("    existing_hash \"" & alert.existingHash & "\"\n")
  result.add("    new_hash      \"" & alert.newHash & "\"\n")
  result.add("}\n")

proc formatAlert*(c: IntraOrgCollision, detectedAt: string): string =
  ## Format an intra-org leaf-name collision as a KDL node.
  "collision namespace=\"" & c.namespace &
    "\" name=\"" & c.name &
    "\" existing-repo=\"" & c.existingRepo &
    "\" new-repo=\"" & c.newRepo &
    "\" detected_at=\"" & detectedAt & "\"\n"

proc formatAlert*(i: IdentityDrift, detectedAt: string): string =
  ## Format a namespace identity-drift event as a KDL node.
  ## Distinct node name ("identity-drift") so triage tooling can
  ## filter by severity independently of content-drift events.
  "identity-drift name=\"" & i.name &
    "\" stored=\"" & i.storedNamespace &
    "\" rederived=\"" & i.rederivedNamespace &
    "\" detected_at=\"" & detectedAt & "\"\n"

# ---------------------------------------------------------------------------
# Legacy thin wrappers kept for any callers that pass DriftAlert directly
# ---------------------------------------------------------------------------

proc formatDriftAlert*(alert: DriftAlert, detectedAt: string): string =
  ## Thin alias — delegates to the overloaded formatAlert.
  formatAlert(alert, detectedAt)

proc appendAlert*(existing: string, alert: DriftAlert, detectedAt: string): string =
  ## Returns `existing` with `alert` appended. Append-only — never
  ## mutates prior entries.
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(alert, detectedAt))

proc appendAlert*(existing: string, c: IntraOrgCollision, detectedAt: string): string =
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(c, detectedAt))

proc appendAlert*(existing: string, i: IdentityDrift, detectedAt: string): string =
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(i, detectedAt))
