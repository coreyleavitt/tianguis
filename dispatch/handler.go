package function

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
)

// PublishRequest is the JSON body of POST /v1/publish.
//
// Dispatch is intentionally NOT a cryptographic trust authority — it
// only verifies enough to filter obvious spam (valid OIDC token from a
// recognized issuer, identity claim consistent with declared repo) and
// then relays to the commit workflow. The commit workflow (which runs
// in GH Actions with a Sigstore-trusted identity) does the actual cosign
// verification of the artifact.
//
// See dispatch_security_architecture memory for the architectural
// reasoning; serverless functions don't fit Sigstore's federation model
// so the trust root lives in GH Actions instead.
type PublishRequest struct {
	Name     string `json:"name"`      // package name to publish under
	Version  string `json:"version"`   // semver tag the author published (e.g. "v1.2.3")
	OciRef   string `json:"oci_ref"`   // <registry>/<repo>@sha256:<digest>
	Provider string `json:"provider"`  // "github" | "gitlab" | "codeberg" | ...
	RepoURL  string `json:"repo_url"`  // URL of the source repo making the request
	SignedBy string `json:"signed_by"` // OIDC identity that cosign-signed the artifact;
	                                   // the commit workflow re-verifies this against
	                                   // the actual cosign signature on the artifact
	DryRun   bool   `json:"dry_run,omitempty"` // when true, run OIDC + identity checks
	                                            // but skip the workflow_dispatch (used for
	                                            // author-side smoke testing)
}

// Dependencies bundles the injectable collaborators of the publish handler.
type Dependencies struct {
	OIDC   OIDCVerifier
	GitHub GitHubAPI

	// KeepaliveSecret gates POST /v1/keepalive. When empty the keepalive
	// route is disabled (returns 503) — fail-closed, no insecure default.
	// The Scaleway cron trigger sends this secret in the request body; it
	// stops the public endpoint from letting anyone spend the App's GitHub
	// API budget by hammering the enable calls.
	KeepaliveSecret string
}

// NewRouter — R3a-era constructor. Kept for tests that don't exercise the
// post-OIDC pipeline (just OIDC + body + identity check).
func NewRouter(verifier OIDCVerifier) http.Handler {
	return NewRouterWithDeps(Dependencies{OIDC: verifier})
}

// NewRouterWithDeps wires the full publish pipeline. Each Dependency may
// be nil; the handler skips the corresponding step when so. Tests use
// this to inject a fake GitHubAPI.
func NewRouterWithDeps(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/publish", publishHandler(deps))
	// Scaleway cron triggers POST their args to the function ROOT ("/"), not a
	// sub-path, so the keepalive heartbeat must be served there. POST /{$}
	// matches ONLY the exact root (unmatched sub-paths stay 404). /v1/keepalive
	// is also registered for explicit/manual invocation and parity with publish.
	keepalive := keepaliveHandler(deps)
	mux.HandleFunc("POST /v1/keepalive", keepalive)
	mux.HandleFunc("POST /{$}", keepalive)
	mux.HandleFunc("GET /healthz", healthHandler)
	return mux
}

// IndexRepo target — constant for now (the registry IS coreyleavitt/tianguis).
const (
	indexRepoOwner      = "coreyleavitt"
	indexRepoName       = "tianguis"
	commitEntryWorkflow = "commit-entry.yaml"
)

// keepaliveWorkflows is the set of schedule-triggered workflows the keepalive
// heartbeat keeps enabled. Only `vendor.yaml` is cron-triggered today (the
// rest are event-triggered and never auto-disabled). Add to this slice as
// more cron workflows appear.
var keepaliveWorkflows = []string{"vendor.yaml"}

func publishHandler(deps Dependencies) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, err := extractBearer(r.Header.Get("Authorization"))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "missing_or_malformed_bearer", err.Error())
			return
		}

		claims, err := deps.OIDC.Verify(r.Context(), token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid_token", err.Error())
			return
		}

		var req PublishRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "malformed_body", err.Error())
			return
		}

		for _, missing := range missingFields(&req) {
			writeError(w, http.StatusBadRequest, "missing_field", "required field: "+missing)
			return
		}

		// Identity cross-check: the OIDC token's repo identity must match
		// the body's declared RepoURL. Cheap spam filter; the commit
		// workflow is the cryptographic trust root.
		if expected, ok := identityMatchesRepoURL(claims, req.RepoURL); !ok {
			writeError(w, http.StatusForbidden, "identity_mismatch",
				"OIDC token attests repo "+expected+
					" but publish request claims "+req.RepoURL)
			return
		}

		// Dry-run: identity checks above already ran (so this isn't a
		// backdoor); just don't trigger the commit workflow. Authors use
		// this to verify their OIDC + identity setup before going live.
		if req.DryRun {
			writeJSON(w, http.StatusOK, map[string]string{"status": "accepted (dry-run)"})
			return
		}

		// Trigger the commit workflow. The workflow re-verifies the
		// author's cosign signature against the OCI artifact before
		// committing — dispatch is just the auth-gated relay.
		if deps.GitHub != nil {
			// P2.1/P2.2: the namespace is NOT supplied by dispatch. The
			// commit-entry workflow derives it inside the tianguis binary from
			// the cosign-verified OIDC SAN (the single source of truth, host/org
			// form). The old org-only deriveNamespace here was a divergent fourth
			// derivation; it is deleted.
			inputs := map[string]string{
				"name":      req.Name,
				"version":   req.Version,
				"oci_ref":   req.OciRef,
				"upstream":  req.RepoURL,
				"signed_by": req.SignedBy,
			}
			if err := deps.GitHub.DispatchWorkflow(r.Context(),
				indexRepoOwner, indexRepoName, commitEntryWorkflow, inputs); err != nil {
				writeError(w, http.StatusBadGateway, "workflow_dispatch_failed", err.Error())
				return
			}
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
	}
}

// keepaliveRequest is the JSON body of POST /v1/keepalive. The shared secret
// is carried in the body because Scaleway cron triggers deliver their `args`
// as the request body (custom headers aren't available on a cron trigger).
type keepaliveRequest struct {
	Secret string `json:"secret"`
}

// keepaliveHandler re-enables the cron-triggered workflows so GitHub's 60-day
// inactivity auto-disable can't permanently shut them off. Invoked by a
// Scaleway cron trigger on a cadence well under 60 days. The trigger lives off
// GitHub's inactivity clock, so this RECOVERS a workflow that has already been
// disabled — the property an in-repo keepalive step structurally can't have
// (a disabled workflow never runs its own keepalive).
func keepaliveHandler(deps Dependencies) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if deps.KeepaliveSecret == "" {
			writeError(w, http.StatusServiceUnavailable, "keepalive_disabled",
				"keepalive is not configured (TIANGUIS_KEEPALIVE_SECRET unset)")
			return
		}

		var req keepaliveRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "malformed_body", err.Error())
			return
		}
		// Constant-time compare so the endpoint doesn't leak the secret via
		// response timing. Mismatched lengths compare as not-equal.
		if subtle.ConstantTimeCompare([]byte(req.Secret), []byte(deps.KeepaliveSecret)) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "invalid keepalive secret")
			return
		}

		if deps.GitHub == nil {
			writeError(w, http.StatusServiceUnavailable, "github_unconfigured",
				"no GitHub client wired")
			return
		}

		enabled := make([]string, 0, len(keepaliveWorkflows))
		for _, wf := range keepaliveWorkflows {
			if err := deps.GitHub.EnableWorkflow(r.Context(),
				indexRepoOwner, indexRepoName, wf); err != nil {
				// Fail loud on the first error so the cron run shows red and
				// the next heartbeat retries; partial success is reported in
				// the detail for observability.
				writeError(w, http.StatusBadGateway, "enable_failed",
					"enabled "+strings.Join(enabled, ",")+"; failed on "+wf+": "+err.Error())
				return
			}
			enabled = append(enabled, wf)
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"status":  "ok",
			"enabled": enabled,
		})
	}
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// identityMatchesRepoURL derives the repo identity the OIDC token attests
// to and compares it to the body's declared RepoURL.
// Returns (expectedRepoURL, match).
//
// Per-provider claim extraction:
//   - GitHub Actions: `repository` claim = "owner/name" → https://github.com/owner/name
//   - GitLab CI:      `project_path`     = "group/.../proj" → https://gitlab.com/group/.../proj
//
// Adding a new provider = adding one more case here. Failing closed when
// no recognized claim is present is intentional.
func identityMatchesRepoURL(c *Claims, repoURL string) (expected string, match bool) {
	if repository, ok := c.IssuerSpecific["repository"].(string); ok && repository != "" {
		expected = "https://github.com/" + repository
		return expected, expected == repoURL
	}
	if projectPath, ok := c.IssuerSpecific["project_path"].(string); ok && projectPath != "" {
		expected = "https://gitlab.com/" + projectPath
		return expected, expected == repoURL
	}
	return "", false
}

func extractBearer(header string) (string, error) {
	if header == "" {
		return "", errMissingAuthHeader
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return "", errMissingAuthHeader
	}
	token := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	if token == "" {
		return "", errMissingAuthHeader
	}
	return token, nil
}

func missingFields(req *PublishRequest) []string {
	var missing []string
	if req.Name == "" {
		missing = append(missing, "name")
	}
	if req.Version == "" {
		missing = append(missing, "version")
	}
	if req.OciRef == "" {
		missing = append(missing, "oci_ref")
	}
	if req.Provider == "" {
		missing = append(missing, "provider")
	}
	if req.RepoURL == "" {
		missing = append(missing, "repo_url")
	}
	if req.SignedBy == "" {
		missing = append(missing, "signed_by")
	}
	return missing
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, errCode, detail string) {
	writeJSON(w, code, map[string]string{
		"error":  errCode,
		"detail": detail,
	})
}

type sentinelError string

func (e sentinelError) Error() string { return string(e) }

const errMissingAuthHeader = sentinelError("missing or malformed Authorization: Bearer header")
