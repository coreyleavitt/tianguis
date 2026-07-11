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
##
##   reject namespace-underivable signed_by="<san>" reason="<DerivationError>" detected_at="<ISO>"

import ./merge
import ../namespace
import ../kdl_io  # for kdlEscapeString

# ---------------------------------------------------------------------------
# Overloaded formatAlert — one per payload type (no sum-wrapper)
# ---------------------------------------------------------------------------

proc formatAlert*(alert: DriftAlert, detectedAt: string): string =
  ## Format a content-hash drift event as a KDL block.
  result.add("drift \"" & kdlEscapeString(alert.packageName) & "\" {\n")
  result.add("    version       \"" & kdlEscapeString(alert.version) & "\"\n")
  result.add("    detected_at   \"" & kdlEscapeString(detectedAt) & "\"\n")
  result.add("    existing_hash \"" & kdlEscapeString(alert.existingHash) & "\"\n")
  result.add("    new_hash      \"" & kdlEscapeString(alert.newHash) & "\"\n")
  result.add("}\n")

proc formatAlert*(c: IntraOrgCollision, detectedAt: string): string =
  ## Format an intra-org leaf-name collision as a KDL node.
  "collision namespace=\"" & kdlEscapeString(c.namespace) &
    "\" name=\"" & kdlEscapeString(c.name) &
    "\" existing-repo=\"" & kdlEscapeString(c.existingRepo) &
    "\" new-repo=\"" & kdlEscapeString(c.newRepo) &
    "\" detected_at=\"" & kdlEscapeString(detectedAt) & "\"\n"

proc formatAlert*(i: IdentityDrift, detectedAt: string): string =
  ## Format a namespace identity-drift event as a KDL node.
  ## Distinct node name ("identity-drift") so triage tooling can
  ## filter by severity independently of content-drift events.
  "identity-drift name=\"" & kdlEscapeString(i.name) &
    "\" stored=\"" & kdlEscapeString(i.storedNamespace) &
    "\" rederived=\"" & kdlEscapeString(i.rederivedNamespace) &
    "\" detected_at=\"" & kdlEscapeString(detectedAt) & "\"\n"

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

proc formatAlert*(m: MissingAttestationAlert, detectedAt: string): string =
  ## Format a publish-time attestation-epoch-gate rejection (S5) as a KDL node.
  ## Distinct node name so triage tooling can filter epoch-gate rejects
  ## independently of content/identity drift.
  "missing-attestation namespace=\"" & kdlEscapeString(m.namespace) &
    "\" name=\"" & kdlEscapeString(m.packageName) &
    "\" version=\"" & kdlEscapeString(m.version) &
    "\" published_at=\"" & kdlEscapeString(m.publishedAt) &
    "\" epoch=\"" & kdlEscapeString(m.epoch) &
    "\" detected_at=\"" & kdlEscapeString(detectedAt) & "\"\n"

proc appendAlert*(existing: string, m: MissingAttestationAlert, detectedAt: string): string =
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(m, detectedAt))

proc formatAlert*(s: SignerMismatchAlert, detectedAt: string): string =
  ## Format a signer-continuity ratchet rejection (rfc-attestation-delivery
  ## S8 Layer 3 anti-takeover guard, tianguis#42) as a KDL node. Distinct
  ## node name so triage tooling can filter takeover-guard rejects
  ## independently of content/identity drift — this is the highest-severity
  ## alert kind (a different signer attempted to publish under an
  ## already-owned package).
  "signer-mismatch namespace=\"" & kdlEscapeString(s.namespace) &
    "\" name=\"" & kdlEscapeString(s.packageName) &
    "\" version=\"" & kdlEscapeString(s.version) &
    "\" pinned_signer=\"" & kdlEscapeString(s.pinnedSigner) &
    "\" incoming_signer=\"" & kdlEscapeString(s.incomingSigner) &
    "\" detected_at=\"" & kdlEscapeString(detectedAt) & "\"\n"

proc appendAlert*(existing: string, s: SignerMismatchAlert, detectedAt: string): string =
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(s, detectedAt))

# ---------------------------------------------------------------------------
# Publish-rejection alert — namespace-underivable (P2.1)
# ---------------------------------------------------------------------------

proc formatAlert*(signedBy: string, reason: DerivationError, detectedAt: string): string =
  ## Format a namespace-underivable publish rejection as a KDL node.
  ## Node: `reject namespace-underivable signed_by="…" reason="…" detected_at="…"`
  ##
  ## `reason` is the DerivationError variant serialized as a kebab-case string
  ## so alert-triage tooling can filter by cause without string surgery.
  ## `signedBy` is escaped — it originates from caller input (the OIDC SAN
  ## that failed derivation) and may contain characters that would corrupt KDL.
  let reasonStr = case reason
    of derrUnparseable:       "unparseable"
    of derrNoOrg:             "no-org"
    of derrGitlabNestedGroup: "gitlab-nested-group"
  "reject namespace-underivable" &
    " signed_by=\"" & kdlEscapeString(signedBy) & "\"" &
    " reason=\"" & reasonStr & "\"" &
    " detected_at=\"" & kdlEscapeString(detectedAt) & "\"\n"

proc appendAlert*(existing: string, signedBy: string, reason: DerivationError,
                  detectedAt: string): string =
  ## Append a namespace-underivable rejection entry. Append-only — never
  ## mutates prior entries.
  result = existing
  if result.len > 0 and result[^1] != '\n':
    result.add('\n')
  result.add(formatAlert(signedBy, reason, detectedAt))
