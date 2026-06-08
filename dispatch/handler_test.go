package function

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// testIssuer stands up a minimal in-process OIDC issuer: an RSA keypair,
// a JWKS endpoint that publishes the public key, and a helper to mint
// signed tokens for tests. Lets us exercise the real verifier code path
// against test-controlled tokens — no mocking the verifier itself.
type testIssuer struct {
	server      *httptest.Server
	privateKey  *rsa.PrivateKey
	keyID       string
	issuer      string
}

func newTestIssuer(t *testing.T) *testIssuer {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa keygen: %v", err)
	}
	keyID := "test-key-1"

	jwks := map[string]any{
		"keys": []map[string]any{{
			"kty": "RSA",
			"kid": keyID,
			"use": "sig",
			"alg": "RS256",
			"n":   base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
			"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
		}},
	}
	jwksJSON, _ := json.Marshal(jwks)

	mux := http.NewServeMux()
	ti := &testIssuer{privateKey: priv, keyID: keyID}
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"issuer":%q,"jwks_uri":"%s/.well-known/jwks.json"}`, ti.issuer, ti.issuer)
	})
	mux.HandleFunc("/.well-known/jwks.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(jwksJSON)
	})
	ti.server = httptest.NewServer(mux)
	ti.issuer = ti.server.URL
	return ti
}

func (ti *testIssuer) close() { ti.server.Close() }

func (ti *testIssuer) signToken(t *testing.T, claims jwt.Claims) string {
	t.Helper()
	sk := jose.SigningKey{
		Algorithm: jose.RS256,
		Key:       jose.JSONWebKey{Key: ti.privateKey, KeyID: ti.keyID},
	}
	signer, err := jose.NewSigner(sk, &jose.SignerOptions{})
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	tok, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return tok
}

// TestTracer — the load-bearing end-to-end: a valid OIDC bearer + valid
// JSON body produces 200. Proves the entire OIDC verification + request
// parsing + handler routing pipeline works.
func TestTracer_ValidTokenAndBodyReturns200(t *testing.T) {
	ti := newTestIssuer(t)
	defer ti.close()

	verifier := NewMultiIssuerVerifier(context.Background(), []IssuerConfig{{
		Name:      "test",
		URL:       ti.issuer,
		JWKSURL:   ti.issuer + "/.well-known/jwks.json",
		Audiences: []string{"sigstore"},
	}})

	// signTokenWithRepository carries the standard claims AND a GitHub-shape
	// repository claim — matches what real GH Actions OIDC tokens carry,
	// and matches the body's RepoURL so the R3c identity cross-check passes.
	token := ti.signTokenWithRepository(t, "coreyleavitt/sample")

	body, _ := json.Marshal(PublishRequest{
		Name:     "sample",
		Version:  "v1.0.0",
		OciRef:   "ghcr.io/coreyleavitt/sample@sha256:abc123",
		Provider: "github",
		RepoURL:  "https://github.com/coreyleavitt/sample",
		SignedBy: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/publish", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rec := httptest.NewRecorder()
	NewRouter(verifier).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d; body=%s", rec.Code, rec.Body.String())
	}
}

// validReqBody returns a request body that passes shape validation
// (cycles 8-9 mutate it to trigger 400s).
func validReqBody() []byte {
	body, _ := json.Marshal(PublishRequest{
		Name:     "sample",
		Version:  "v1.0.0",
		OciRef:   "ghcr.io/coreyleavitt/sample@sha256:abc123",
		Provider: "github",
		RepoURL:  "https://github.com/coreyleavitt/sample",
		SignedBy: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
	})
	return body
}

func freshVerifier(t *testing.T, ti *testIssuer) OIDCVerifier {
	return NewMultiIssuerVerifier(context.Background(), []IssuerConfig{{
		Name: "test", URL: ti.issuer,
		JWKSURL:   ti.issuer + "/.well-known/jwks.json",
		Audiences: []string{"sigstore"},
	}})
}

func validClaims(ti *testIssuer) jwt.Claims {
	return jwt.Claims{
		Issuer:   ti.issuer,
		Subject:  "repo:x/y:ref:refs/tags/v1.0.0",
		Audience: jwt.Audience{"sigstore"},
		Expiry:   jwt.NewNumericDate(time.Now().Add(5 * time.Minute)),
	}
}

func doRequest(t *testing.T, h http.Handler, body []byte, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/publish", bytes.NewReader(body))
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// --- cycle 2: missing Authorization header ---
func TestMissingAuthHeader_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 3: malformed JWT (not three dot-separated segments) ---
func TestMalformedJWT_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer not.a.real.jwt.extra.segments")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 4: JWT signed by an unknown key ---
func TestJWTSignedByUnknownKey_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()

	// Sign with a key the verifier never publishes — fresh keypair, not in JWKS.
	otherPriv, _ := rsa.GenerateKey(rand.Reader, 2048)
	sk := jose.SigningKey{
		Algorithm: jose.RS256,
		Key:       jose.JSONWebKey{Key: otherPriv, KeyID: "rogue-key"},
	}
	signer, _ := jose.NewSigner(sk, &jose.SignerOptions{})
	tok, _ := jwt.Signed(signer).Claims(validClaims(ti)).Serialize()

	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer "+tok)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 5: expired JWT ---
func TestExpiredJWT_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	expired := jwt.Claims{
		Issuer:   ti.issuer,
		Subject:  "x",
		Audience: jwt.Audience{"sigstore"},
		Expiry:   jwt.NewNumericDate(time.Now().Add(-5 * time.Minute)),
	}
	tok := ti.signToken(t, expired)
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer "+tok)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 6: JWT from unknown issuer ---
func TestUnknownIssuer_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	c := validClaims(ti)
	c.Issuer = "https://evil.example.com"
	tok := ti.signToken(t, c)
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer "+tok)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 7: JWT with wrong audience ---
func TestWrongAudience_Returns401(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	c := validClaims(ti)
	c.Audience = jwt.Audience{"some-other-aud"}
	tok := ti.signToken(t, c)
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer "+tok)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 8: valid token + malformed JSON body ---
func TestMalformedJSON_Returns400(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signToken(t, validClaims(ti))
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), []byte("{not json"), "Bearer "+tok)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 9: valid token + body missing a required field ---
func TestMissingRequiredField_Returns400(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signToken(t, validClaims(ti))

	cases := []struct {
		name string
		body map[string]string
	}{
		{"missing name", map[string]string{"version": "v1", "oci_ref": "x", "provider": "github", "repo_url": "https://x"}},
		{"missing version", map[string]string{"name": "x", "oci_ref": "x", "provider": "github", "repo_url": "https://x"}},
		{"missing oci_ref", map[string]string{"name": "x", "version": "v1", "provider": "github", "repo_url": "https://x"}},
		{"missing provider", map[string]string{"name": "x", "version": "v1", "oci_ref": "x", "repo_url": "https://x"}},
		{"missing repo_url", map[string]string{"name": "x", "version": "v1", "oci_ref": "x", "provider": "github"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := json.Marshal(tc.body)
			rec := doRequest(t, NewRouter(freshVerifier(t, ti)), body, "Bearer "+tok)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

// --- cycle 10: GET /healthz → 200 ---
func TestHealthz_Returns200(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	NewRouter(freshVerifier(t, ti)).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

// --- cycle 11: unknown path → 404 ---
func TestUnknownPath_Returns404(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	req := httptest.NewRequest(http.MethodGet, "/no-such-endpoint", nil)
	rec := httptest.NewRecorder()
	NewRouter(freshVerifier(t, ti)).ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("got %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycle 1 — identity cross-check
//
// The OIDC token attests "this workflow run is on repo X." The dispatch
// body claims "publish for repo Y." These MUST match — otherwise an
// attacker with a valid OIDC token for their own repo could publish
// entries naming someone else's repo.
// ---------------------------------------------------------------------------

// signTokenWithRepository signs a token carrying the standard claims plus
// a GitHub-Actions-shape "repository" claim (e.g. "owner/name").
func (ti *testIssuer) signTokenWithRepository(t *testing.T, repository string) string {
	t.Helper()
	type ghClaims struct {
		Repository string `json:"repository"`
	}
	sk := jose.SigningKey{
		Algorithm: jose.RS256,
		Key:       jose.JSONWebKey{Key: ti.privateKey, KeyID: ti.keyID},
	}
	signer, _ := jose.NewSigner(sk, &jose.SignerOptions{})
	tok, err := jwt.Signed(signer).
		Claims(validClaims(ti)).
		Claims(ghClaims{Repository: repository}).
		Serialize()
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return tok
}

func bodyForRepo(repoURL string) []byte {
	body, _ := json.Marshal(PublishRequest{
		Name:     "sample",
		Version:  "v1.0.0",
		OciRef:   "ghcr.io/x/sample@sha256:abc123",
		Provider: "github",
		RepoURL:  repoURL,
		SignedBy: repoURL + "/.github/workflows/publish.yaml@refs/tags/v1.0.0",
	})
	return body
}

// TestIdentityCrossCheck_Match — token's repository claim corresponds to
// the body's RepoURL → endpoint accepts (200 today; will become "proceed
// to cosign verify" in cycle 3).
func TestIdentityCrossCheck_Match(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on identity match; got %d body=%s", rec.Code, rec.Body.String())
	}
}

// TestIdentityCrossCheck_Mismatch — token attests one repo, body claims
// another. Anti-impersonation guard: reject with 403.
func TestIdentityCrossCheck_Mismatch(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signTokenWithRepository(t, "attacker/their-repo")
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)),
		bodyForRepo("https://github.com/victim/their-package"),
		"Bearer "+tok)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403 on identity mismatch; got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("identity")) {
		t.Fatalf("403 body should mention identity mismatch; got %s", rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycle 2 — per-provider claim extraction
//
// GitHub tokens carry `repository` ("owner/name"). GitLab tokens carry
// `project_path` ("group/subgroup/project"). Each maps to a canonical
// repo URL via its issuer's URL scheme.
// ---------------------------------------------------------------------------

// signTokenWithCustomClaims signs a token with arbitrary additional claims.
func (ti *testIssuer) signTokenWithCustomClaims(t *testing.T, extra map[string]any) string {
	t.Helper()
	sk := jose.SigningKey{
		Algorithm: jose.RS256,
		Key:       jose.JSONWebKey{Key: ti.privateKey, KeyID: ti.keyID},
	}
	signer, _ := jose.NewSigner(sk, &jose.SignerOptions{})
	tok, err := jwt.Signed(signer).
		Claims(validClaims(ti)).
		Claims(extra).
		Serialize()
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return tok
}

// freshVerifierAt — like freshVerifier but lets the test set the issuer URL.
// GitLab tokens have iss=https://gitlab.com; the test issuer's URL changes
// per case, so we configure the verifier to accept whatever the test mints.
func freshVerifierAt(t *testing.T, ti *testIssuer) OIDCVerifier {
	return NewMultiIssuerVerifier(context.Background(), []IssuerConfig{{
		Name: "test", URL: ti.issuer,
		JWKSURL:   ti.issuer + "/.well-known/jwks.json",
		Audiences: []string{"sigstore"},
	}})
}

func TestIdentityCrossCheck_GitLab_Match(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signTokenWithCustomClaims(t, map[string]any{
		"project_path": "mygroup/sub/myproj",
	})
	body, _ := json.Marshal(PublishRequest{
		Name:     "sample",
		Version:  "v1.0.0",
		OciRef:   "registry.gitlab.com/x/sample@sha256:abc",
		Provider: "gitlab",
		RepoURL:  "https://gitlab.com/mygroup/sub/myproj",
		SignedBy: "https://gitlab.com/mygroup/sub/myproj//.gitlab-ci.yml@refs/tags/v1.0.0",
	})
	rec := doRequest(t, NewRouter(freshVerifierAt(t, ti)), body, "Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on GitLab identity match; got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestIdentityCrossCheck_GitLab_Mismatch(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signTokenWithCustomClaims(t, map[string]any{
		"project_path": "attacker/their-project",
	})
	body, _ := json.Marshal(PublishRequest{
		Name:     "sample",
		Version:  "v1.0.0",
		OciRef:   "registry.gitlab.com/x/sample@sha256:abc",
		Provider: "gitlab",
		RepoURL:  "https://gitlab.com/victim/their-project",
		SignedBy: "https://gitlab.com/victim/their-project//.gitlab-ci.yml@refs/tags/v1.0.0",
	})
	rec := doRequest(t, NewRouter(freshVerifierAt(t, ti)), body, "Bearer "+tok)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403 on GitLab identity mismatch; got %d body=%s", rec.Code, rec.Body.String())
	}
}

// TestIdentityCrossCheck_NoRecognizedClaim — token validates but has neither
// `repository` (GitHub) nor `project_path` (GitLab) — must fail closed.
func TestIdentityCrossCheck_NoRecognizedClaim(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	tok := ti.signToken(t, validClaims(ti))  // bare claims, no provider-specific
	rec := doRequest(t, NewRouter(freshVerifier(t, ti)), validReqBody(), "Bearer "+tok)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403 when no recognized identity claim; got %d body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycles 3-6 REMOVED in refactor: dispatch no longer does cosign verify
// or Rekor attest. Trust authority moved to the commit-entry.yaml workflow
// (GH Actions has Sigstore-trusted identity; Scaleway does not). See
// dispatch_security_architecture memory.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// R3c cycles 7+8 — workflow_dispatch via GitHub App
//
// After OIDC verify + identity cross-check, dispatch triggers commit-entry.yaml
// on coreyleavitt/tianguis via a GH App installation token. The commit
// workflow does the cosign verify-blob + Rekor attest under its own GH
// Actions identity.
// ---------------------------------------------------------------------------

type fakeGitHub struct {
	calls       []ghCall
	returnErr   error
	enableCalls []ghCall
	enableErr   error
}

type ghCall struct {
	owner, repo, workflowFile string
	inputs                    map[string]string
}

func (f *fakeGitHub) DispatchWorkflow(_ context.Context, owner, repo, workflowFile string, inputs map[string]string) error {
	f.calls = append(f.calls, ghCall{owner, repo, workflowFile, inputs})
	return f.returnErr
}

func (f *fakeGitHub) EnableWorkflow(_ context.Context, owner, repo, workflowFile string) error {
	f.enableCalls = append(f.enableCalls, ghCall{owner, repo, workflowFile, nil})
	return f.enableErr
}

func fullDeps(t *testing.T, ti *testIssuer, gh GitHubAPI) Dependencies {
	return Dependencies{
		OIDC:   freshVerifier(t, ti),
		GitHub: gh,
	}
}

func TestWorkflowDispatch_CalledWithFullPayload(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	gh := &fakeGitHub{}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(fullDeps(t, ti, gh)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.calls) != 1 {
		t.Fatalf("GitHub API should be called exactly once; got %d", len(gh.calls))
	}
	c := gh.calls[0]
	if c.owner != "coreyleavitt" || c.repo != "tianguis" {
		t.Fatalf("dispatch target wrong: got %s/%s, want coreyleavitt/tianguis", c.owner, c.repo)
	}
	if c.workflowFile != "commit-entry.yaml" {
		t.Fatalf("dispatch workflow wrong: got %q, want commit-entry.yaml", c.workflowFile)
	}
	want := map[string]string{
		"name":      "sample",
		"version":   "v1.0.0",
		"oci_ref":   "ghcr.io/x/sample@sha256:abc123",
		"upstream":  "https://github.com/coreyleavitt/sample",
		"signed_by": "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
	}
	for k, v := range want {
		if c.inputs[k] != v {
			t.Errorf("inputs[%q] = %q; want %q", k, c.inputs[k], v)
		}
	}
}

func TestWorkflowDispatch_FailureFailsClosed(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	gh := &fakeGitHub{returnErr: errors.New("github API 502")}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(fullDeps(t, ti, gh)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502 when workflow_dispatch fails; got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("workflow_dispatch_failed")) {
		t.Fatalf("502 body should mention workflow_dispatch_failed; got %s", rec.Body.String())
	}
}


// ---------------------------------------------------------------------------
// --- Dry-run mode: client sets {"dry_run": true} in body; dispatch runs
// the full verification chain (OIDC + identity) but skips the
// workflow_dispatch and returns "accepted (dry-run)". Lets authors
// smoke-test OIDC + identity flow without triggering a real index commit.
// ---------------------------------------------------------------------------

func TestDryRun_SkipsWorkflowDispatch(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	gh := &fakeGitHub{}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")

	body := []byte(`{
		"name": "sample",
		"version": "v1.0.0",
		"oci_ref": "ghcr.io/x/sample@sha256:abc123",
		"provider": "github",
		"repo_url": "https://github.com/coreyleavitt/sample",
		"signed_by": "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
		"dry_run": true
	}`)

	rec := doRequest(t, NewRouterWithDeps(fullDeps(t, ti, gh)), body, "Bearer "+tok)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.calls) != 0 {
		t.Errorf("dry-run must NOT call workflow_dispatch; got %d calls", len(gh.calls))
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("dry-run")) {
		t.Errorf("response should indicate dry-run; got %s", rec.Body.String())
	}
}

func TestDryRun_StillEnforcesIdentityCheck(t *testing.T) {
	// Dry-run must NOT be a backdoor around the OIDC identity check.
	ti := newTestIssuer(t); defer ti.close()
	gh := &fakeGitHub{}
	tok := ti.signTokenWithRepository(t, "attacker/their-repo")

	body := []byte(`{
		"name": "sample",
		"version": "v1.0.0",
		"oci_ref": "ghcr.io/x/sample@sha256:abc",
		"provider": "github",
		"repo_url": "https://github.com/coreyleavitt/sample",
		"signed_by": "https://github.com/coreyleavitt/sample/x",
		"dry_run": true
	}`)

	rec := doRequest(t, NewRouterWithDeps(fullDeps(t, ti, gh)), body, "Bearer "+tok)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("dry-run must still enforce identity; want 403, got %d body=%s",
			rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Keepalive — re-enable the cron-triggered workflow(s). Invoked by the
// external Scaleway cron so GitHub's 60-day inactivity auto-disable can't
// permanently shut the vendor cron off.
// ---------------------------------------------------------------------------

func doKeepalive(t *testing.T, h http.Handler, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/keepalive", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestKeepalive_DisabledWhenSecretUnset(t *testing.T) {
	gh := &fakeGitHub{}
	h := NewRouterWithDeps(Dependencies{GitHub: gh}) // no KeepaliveSecret
	rec := doKeepalive(t, h, []byte(`{"secret":"anything"}`))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503 when keepalive unconfigured; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.enableCalls) != 0 {
		t.Fatalf("must not call GitHub when keepalive is disabled; got %d calls", len(gh.enableCalls))
	}
}

func TestKeepalive_WrongSecretRejected(t *testing.T) {
	gh := &fakeGitHub{}
	h := NewRouterWithDeps(Dependencies{GitHub: gh, KeepaliveSecret: "correct-horse"})
	rec := doKeepalive(t, h, []byte(`{"secret":"wrong"}`))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 on wrong secret; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.enableCalls) != 0 {
		t.Fatalf("must not enable on bad secret; got %d calls", len(gh.enableCalls))
	}
}

func TestKeepalive_EnablesVendorWorkflow(t *testing.T) {
	gh := &fakeGitHub{}
	h := NewRouterWithDeps(Dependencies{GitHub: gh, KeepaliveSecret: "correct-horse"})
	rec := doKeepalive(t, h, []byte(`{"secret":"correct-horse"}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on valid keepalive; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.enableCalls) != 1 {
		t.Fatalf("want exactly one enable call; got %d", len(gh.enableCalls))
	}
	c := gh.enableCalls[0]
	if c.owner != "coreyleavitt" || c.repo != "tianguis" || c.workflowFile != "vendor.yaml" {
		t.Fatalf("enable targeted wrong workflow: %+v", c)
	}
}

func TestKeepalive_EnableErrorReturns502(t *testing.T) {
	gh := &fakeGitHub{enableErr: errors.New("github API 403")}
	h := NewRouterWithDeps(Dependencies{GitHub: gh, KeepaliveSecret: "correct-horse"})
	rec := doKeepalive(t, h, []byte(`{"secret":"correct-horse"}`))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502 when enable fails; got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestKeepalive_ServedAtRootForScalewayCron(t *testing.T) {
	// Scaleway cron triggers POST to "/", not "/v1/keepalive" — the heartbeat
	// must work at the function root or the cron can't reach it.
	gh := &fakeGitHub{}
	h := NewRouterWithDeps(Dependencies{GitHub: gh, KeepaliveSecret: "correct-horse"})
	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(`{"secret":"correct-horse"}`)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on root keepalive; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.enableCalls) != 1 || gh.enableCalls[0].workflowFile != "vendor.yaml" {
		t.Fatalf("root POST must enable vendor.yaml; got %+v", gh.enableCalls)
	}
}

func TestKeepalive_MalformedBodyRejected(t *testing.T) {
	gh := &fakeGitHub{}
	h := NewRouterWithDeps(Dependencies{GitHub: gh, KeepaliveSecret: "correct-horse"})
	rec := doKeepalive(t, h, []byte(`not json`))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 on malformed body; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(gh.enableCalls) != 0 {
		t.Fatalf("must not enable on malformed body; got %d calls", len(gh.enableCalls))
	}
}
