package function

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// PublishRequest is the JSON body of POST /v1/publish.
type PublishRequest struct {
	Name     string `json:"name"`      // package name to publish under
	Version  string `json:"version"`   // semver tag the author published (e.g. "v1.2.3" or "1.2.3")
	OciRef   string `json:"oci_ref"`   // <registry>/<repo>@sha256:<digest>
	Provider string `json:"provider"`  // "github" | "gitlab" | "codeberg" | ...
	RepoURL  string `json:"repo_url"`  // URL of the source repo making the request
}

// Dependencies bundles the injectable collaborators of the publish handler.
// Grows as R3c lands more verification primitives. One struct keeps
// signatures stable as fields are added.
type Dependencies struct {
	OIDC   OIDCVerifier
	Cosign CosignVerifier
	Rekor  RekorAttester
	GitHub GitHubAPI
	Now    func() time.Time // injectable clock for deterministic attestation timestamps
}

// IndexRepo is where dispatch sends workflow_dispatch events. Constant
// for now (the registry IS coreyleavitt/tianguis); could become a
// Dependencies field if we ever support multiple index targets.
const (
	indexRepoOwner       = "coreyleavitt"
	indexRepoName        = "tianguis"
	commitEntryWorkflow  = "commit-entry.yaml"
)

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
		var signerIdentity string
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
			signerIdentity = cv.SignerIdentity
		}

		// Rekor attest the verified publish event (when injected). The
		// commit workflow later re-fetches by UUID and verifies independently.
		// Fail-closed: a Rekor failure means we cannot create the public
		// audit trail this design relies on, so we refuse to proceed.
		var rekorUUID string
		if deps.Rekor != nil {
			payload := AttestPayload{
				Name:           req.Name,
				OciRef:         req.OciRef,
				RepoURL:        req.RepoURL,
				SignerIdentity: signerIdentity,
				VerifiedAt:     now(deps),
			}
			uuid, err := deps.Rekor.Attest(r.Context(), payload)
			if err != nil {
				writeError(w, http.StatusServiceUnavailable, "rekor_attest_failed", err.Error())
				return
			}
			rekorUUID = uuid
		}

		// workflow_dispatch trigger (when injected). Carries the verified
		// payload + Rekor UUID so the commit workflow can verify Rekor
		// independently before committing. Fail-closed on API failure.
		if deps.GitHub != nil {
			inputs := map[string]string{
				"name":         req.Name,
				"version":      req.Version,
				"oci_ref":      req.OciRef,
				"namespace":    deriveNamespace(req.RepoURL),
				"upstream":     req.RepoURL,
				"signed_by":    signerIdentity,
				"published_at": now(deps).Format(time.RFC3339),
				"rekor_uuid":   rekorUUID,
			}
			if err := deps.GitHub.DispatchWorkflow(r.Context(),
				indexRepoOwner, indexRepoName, commitEntryWorkflow, inputs); err != nil {
				writeError(w, http.StatusBadGateway, "workflow_dispatch_failed", err.Error())
				return
			}
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"status":     "accepted",
			"rekor_uuid": rekorUUID,
		})
	}
}

// deriveNamespace pulls the GitHub owner from a github.com URL.
// "https://github.com/coreyleavitt/sample" → "coreyleavitt".
// GitLab equivalent (and others) added when needed.
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

func now(deps Dependencies) time.Time {
	if deps.Now != nil {
		return deps.Now()
	}
	return time.Now().UTC()
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
