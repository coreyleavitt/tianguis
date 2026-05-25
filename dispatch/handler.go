package function

import (
	"encoding/json"
	"net/http"
	"strings"
)

// PublishRequest is the JSON body of POST /v1/publish.
type PublishRequest struct {
	Name     string `json:"name"`      // package name to publish under
	OciRef   string `json:"oci_ref"`   // <registry>/<repo>@sha256:<digest>
	Provider string `json:"provider"`  // "github" | "gitlab" | "codeberg" | ...
	RepoURL  string `json:"repo_url"`  // URL of the source repo making the request
}

// Dependencies bundles the injectable collaborators of the publish handler.
// Grows as R3c lands more verification primitives (Rekor attester, GitHub
// API client). One struct keeps signatures stable as fields are added.
type Dependencies struct {
	OIDC   OIDCVerifier
	Cosign CosignVerifier
}

// NewRouter — R3a-era constructor. Wraps NewRouterWithDeps with a Dependencies
// that has only OIDC (no cosign, no Rekor, no GitHub API). Kept for the
// existing tests that don't exercise the post-OIDC pipeline.
func NewRouter(verifier OIDCVerifier) http.Handler {
	return NewRouterWithDeps(Dependencies{OIDC: verifier})
}

// NewRouterWithDeps wires the full publish pipeline. Each Dependency may
// be nil; the handler skips the corresponding step when so. Tests use this
// to inject a fake CosignVerifier (etc.) and exercise the verified path.
func NewRouterWithDeps(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/publish", publishHandler(deps))
	mux.HandleFunc("GET /healthz", healthHandler)
	return mux
}

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

		if expected, ok := identityMatchesRepoURL(claims, req.RepoURL); !ok {
			writeError(w, http.StatusForbidden, "identity_mismatch",
				"OIDC token attests repo "+expected+
					" but publish request claims "+req.RepoURL)
			return
		}

		// Cosign verify (when injected). Verifies the OCI artifact has a
		// cosign signature; signer identity must be prefix-matched against
		// the verified OIDC identity to prevent cross-identity publishing.
		if deps.Cosign != nil {
			cv, err := deps.Cosign.Verify(r.Context(), req.OciRef)
			if err != nil {
				writeError(w, http.StatusUnprocessableEntity, "cosign_verify_failed", err.Error())
				return
			}
			expected, _ := identityMatchesRepoURL(claims, req.RepoURL)
			if !strings.HasPrefix(cv.SignerIdentity, expected) {
				writeError(w, http.StatusUnprocessableEntity, "signer_mismatch",
					"cosign signer identity "+cv.SignerIdentity+
						" does not match the verified OIDC repo "+expected)
				return
			}
		}

		// Rekor attest + workflow_dispatch land in cycles 6-8.
		writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
	}
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
// no recognized claim is present is intentional — an OIDC issuer that
// doesn't bind tokens to a specific source repo can't be trusted for
// repo-scoped publish authorization.
func identityMatchesRepoURL(c *Claims, repoURL string) (expected string, match bool) {
	// GitHub Actions OIDC.
	if repository, ok := c.IssuerSpecific["repository"].(string); ok && repository != "" {
		expected = "https://github.com/" + repository
		return expected, expected == repoURL
	}
	// GitLab CI OIDC.
	if projectPath, ok := c.IssuerSpecific["project_path"].(string); ok && projectPath != "" {
		expected = "https://gitlab.com/" + projectPath
		return expected, expected == repoURL
	}
	// No recognized identity claim → fail closed.
	return "", false
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
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
	if req.OciRef == "" {
		missing = append(missing, "oci_ref")
	}
	if req.Provider == "" {
		missing = append(missing, "provider")
	}
	if req.RepoURL == "" {
		missing = append(missing, "repo_url")
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
