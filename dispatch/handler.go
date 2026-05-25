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

// NewRouter returns an http.Handler routing /v1/publish (POST) and
// /healthz (GET). The verifier is invoked for /v1/publish.
func NewRouter(verifier OIDCVerifier) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/publish", publishHandler(verifier))
	mux.HandleFunc("GET /healthz", healthHandler)
	return mux
}

func publishHandler(verifier OIDCVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, err := extractBearer(r.Header.Get("Authorization"))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "missing_or_malformed_bearer", err.Error())
			return
		}

		claims, err := verifier.Verify(r.Context(), token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid_token", err.Error())
			return
		}

		var req PublishRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "malformed_body", err.Error())
			return
		}

		// Field-presence validation. Per-field error for actionable diagnostics.
		for _, missing := range missingFields(&req) {
			writeError(w, http.StatusBadRequest, "missing_field", "required field: "+missing)
			return
		}

		// Identity cross-check: the OIDC token's repo identity must match
		// the body's declared RepoURL. Without this, an attacker with a
		// valid OIDC token for their own repo could publish entries
		// naming someone else's repo.
		if expected, ok := identityMatchesRepoURL(claims, req.RepoURL); !ok {
			writeError(w, http.StatusForbidden, "identity_mismatch",
				"OIDC token attests repo "+expected+
					" but publish request claims "+req.RepoURL)
			return
		}

		// R3a + identity-match stop here. Cosign verify + Rekor attest +
		// workflow_dispatch land in subsequent cycles.
		writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
	}
}

// identityMatchesRepoURL derives the repo identity the OIDC token attests
// to and compares it to the body's declared RepoURL.
// Returns (expectedRepoURL, match).
//
// Per-provider claim extraction lives here. Cycle 1 implements GitHub
// (uses the `repository` claim of form "owner/name"). Cycle 2 generalizes
// to GitLab (`project_path`) and any future issuer.
func identityMatchesRepoURL(c *Claims, repoURL string) (expected string, match bool) {
	if repository, ok := c.IssuerSpecific["repository"].(string); ok && repository != "" {
		expected = "https://github.com/" + repository
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
