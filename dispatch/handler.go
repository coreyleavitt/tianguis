package function

import (
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
}

// Dependencies bundles the injectable collaborators of the publish handler.
type Dependencies struct {
	OIDC   OIDCVerifier
	GitHub GitHubAPI
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
	mux.HandleFunc("GET /healthz", healthHandler)
	return mux
}

// IndexRepo target — constant for now (the registry IS coreyleavitt/tianguis).
const (
	indexRepoOwner      = "coreyleavitt"
	indexRepoName       = "tianguis"
	commitEntryWorkflow = "commit-entry.yaml"
)

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

		// Trigger the commit workflow. The workflow re-verifies the
		// author's cosign signature against the OCI artifact before
		// committing — dispatch is just the auth-gated relay.
		if deps.GitHub != nil {
			inputs := map[string]string{
				"name":      req.Name,
				"version":   req.Version,
				"oci_ref":   req.OciRef,
				"namespace": deriveNamespace(req.RepoURL),
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

// deriveNamespace pulls the GitHub/GitLab owner from a repo URL.
func deriveNamespace(repoURL string) string {
	const ghPrefix = "https://github.com/"
	if strings.HasPrefix(repoURL, ghPrefix) {
		tail := strings.TrimPrefix(repoURL, ghPrefix)
		if i := strings.Index(tail, "/"); i > 0 {
			return tail[:i]
		}
	}
	const glPrefix = "https://gitlab.com/"
	if strings.HasPrefix(repoURL, glPrefix) {
		tail := strings.TrimPrefix(repoURL, glPrefix)
		if i := strings.Index(tail, "/"); i > 0 {
			return tail[:i]
		}
	}
	return ""
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
