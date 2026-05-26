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
// R3c cycle 3 — cosign verify (happy path, injected verifier)
//
// After identity cross-check, dispatch must verify the OCI artifact is
// cosign-signed before relaying. Injectable CosignVerifier interface
// matches the OIDCVerifier pattern — production uses sigstore-go,
// tests inject a fake.
// ---------------------------------------------------------------------------

type fakeCosign struct {
	wantOciRef    string         // assertion: what we expect to receive
	identity      string         // what the fake returns as the cosign signer's identity
	verifyErr     error          // if non-nil, Verify returns this
	callsReceived []string       // captured oci_refs across calls (for assertions)
}

func (f *fakeCosign) Verify(_ context.Context, ociRef string) (*CosignVerification, error) {
	f.callsReceived = append(f.callsReceived, ociRef)
	if f.verifyErr != nil {
		return nil, f.verifyErr
	}
	return &CosignVerification{SignerIdentity: f.identity}, nil
}

func freshDeps(t *testing.T, ti *testIssuer, cosign CosignVerifier) Dependencies {
	return Dependencies{
		OIDC:   freshVerifier(t, ti),
		Cosign: cosign,
	}
}

// Default fake cosign that returns the OIDC identity we expect — so the
// signer-identity-vs-OIDC check (cycle 5) passes for the happy path tests.
// "https://github.com/coreyleavitt/sample" matches what signTokenWithRepository
// translates to via the GitHub URL mapping.
func okCosign() *fakeCosign {
	return &fakeCosign{identity: "https://github.com/coreyleavitt/sample"}
}

func TestCosignVerify_HappyPath(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	cosign := okCosign()
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(freshDeps(t, ti, cosign)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 when cosign verifies; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(cosign.callsReceived) != 1 {
		t.Fatalf("cosign verifier should have been called exactly once; got %d", len(cosign.callsReceived))
	}
	if cosign.callsReceived[0] != "ghcr.io/x/sample@sha256:abc123" {
		t.Fatalf("cosign should receive the body's oci_ref; got %q", cosign.callsReceived[0])
	}
}

// --- R3c cycle 4 — cosign verify failure → 422 ---
func TestCosignVerify_Failure_Returns422(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	cosign := &fakeCosign{verifyErr: errors.New("signature not found in Rekor")}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(freshDeps(t, ti, cosign)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422 on cosign failure; got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("cosign_verify_failed")) {
		t.Fatalf("422 body should mention cosign_verify_failed; got %s", rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycle 5 — anti-impersonation: cosign signer identity must match OIDC
//
// Without this check, an attacker who validly cosign-signed their own
// artifact could trigger dispatch for it under a victim's repo (assuming
// they could also forge the OIDC token, which they can't — but defense in
// depth: even if OIDC verify is compromised, cosign-identity-vs-OIDC
// catches the cross-identity case).
//
// cosign keyless identities for GH Actions look like:
//   https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0
// We accept a prefix match against the expected repo URL.
// ---------------------------------------------------------------------------

// TestCosignSigner_PrefixMatch — cosign identity starts with the verified
// repo URL (workflow file + ref are appended) → passes.
func TestCosignSigner_PrefixMatch(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	cosign := &fakeCosign{
		identity: "https://github.com/coreyleavitt/sample/.github/workflows/publish.yaml@refs/tags/v1.0.0",
	}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(freshDeps(t, ti, cosign)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on cosign identity prefix-match; got %d body=%s", rec.Code, rec.Body.String())
	}
}

// TestCosignSigner_Mismatch — cosign identity belongs to a different repo
// than the OIDC token attests to → 422.
func TestCosignSigner_Mismatch(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	cosign := &fakeCosign{
		identity: "https://github.com/attacker/their-repo/.github/workflows/x.yaml@refs/heads/main",
	}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(freshDeps(t, ti, cosign)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422 on cosign signer mismatch; got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("signer_mismatch")) {
		t.Fatalf("422 body should mention signer_mismatch; got %s", rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycle 6 — Rekor attest before workflow_dispatch
//
// After all verifications pass, dispatch attests the verified publish event
// to Rekor and gets back a UUID. The UUID propagates into the eventual
// workflow_dispatch payload so the commit workflow can verify independently.
// ---------------------------------------------------------------------------

type fakeRekor struct {
	captured  []AttestPayload
	returnUUID string
	returnErr  error
}

func (f *fakeRekor) Attest(_ context.Context, p AttestPayload) (string, error) {
	f.captured = append(f.captured, p)
	if f.returnErr != nil {
		return "", f.returnErr
	}
	uuid := f.returnUUID
	if uuid == "" {
		uuid = "test-rekor-uuid-1234"
	}
	return uuid, nil
}

func happyDeps(t *testing.T, ti *testIssuer, rekor RekorAttester) Dependencies {
	return Dependencies{
		OIDC:   freshVerifier(t, ti),
		Cosign: okCosign(),
		Rekor:  rekor,
	}
}

func TestRekorAttest_CalledWithVerifiedPayload(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rekor := &fakeRekor{returnUUID: "uuid-abc-123"}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(happyDeps(t, ti, rekor)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200; got %d body=%s", rec.Code, rec.Body.String())
	}
	if len(rekor.captured) != 1 {
		t.Fatalf("Rekor attester should be called exactly once; got %d", len(rekor.captured))
	}
	p := rekor.captured[0]
	if p.Name != "sample" || p.OciRef != "ghcr.io/x/sample@sha256:abc123" {
		t.Fatalf("attestation payload missing or wrong: %+v", p)
	}
	if p.RepoURL != "https://github.com/coreyleavitt/sample" {
		t.Fatalf("payload RepoURL wrong: %q", p.RepoURL)
	}
	if p.SignerIdentity != "https://github.com/coreyleavitt/sample" {
		t.Fatalf("payload SignerIdentity should be the cosign-verified identity; got %q", p.SignerIdentity)
	}
	if p.VerifiedAt.IsZero() {
		t.Fatalf("payload VerifiedAt should be populated")
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("uuid-abc-123")) {
		t.Fatalf("response body should include the Rekor UUID; got %s", rec.Body.String())
	}
}

func TestRekorAttest_FailureFailsClosed(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rekor := &fakeRekor{returnErr: errors.New("rekor upload timeout")}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(happyDeps(t, ti, rekor)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503 when Rekor attest fails (fail-closed); got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("rekor_attest_failed")) {
		t.Fatalf("503 body should mention rekor_attest_failed; got %s", rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// R3c cycles 7+8 — workflow_dispatch via GitHub App
//
// After all verification + Rekor attest, dispatch triggers commit-entry.yaml
// on coreyleavitt/tianguis via a GH App installation token. The dispatched
// payload carries everything the commit workflow needs to verify the Rekor
// entry and merge the index entry.
// ---------------------------------------------------------------------------

type fakeGitHub struct {
	calls     []ghCall
	returnErr error
}

type ghCall struct {
	owner, repo, workflowFile string
	inputs                    map[string]string
}

func (f *fakeGitHub) DispatchWorkflow(_ context.Context, owner, repo, workflowFile string, inputs map[string]string) error {
	f.calls = append(f.calls, ghCall{owner, repo, workflowFile, inputs})
	return f.returnErr
}

func fullDeps(t *testing.T, ti *testIssuer, rekor RekorAttester, gh GitHubAPI) Dependencies {
	return Dependencies{
		OIDC:    freshVerifier(t, ti),
		Cosign:  okCosign(),
		Rekor:   rekor,
		GitHub:  gh,
		Now:     func() time.Time { return time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC) },
	}
}

func TestWorkflowDispatch_CalledWithFullPayload(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rekor := &fakeRekor{returnUUID: "rekor-uuid-xyz"}
	gh := &fakeGitHub{}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(fullDeps(t, ti, rekor, gh)),
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
		"name":         "sample",
		"oci_ref":      "ghcr.io/x/sample@sha256:abc123",
		"namespace":    "coreyleavitt",
		"upstream":     "https://github.com/coreyleavitt/sample",
		"signed_by":    "https://github.com/coreyleavitt/sample",
		"published_at": "2026-06-01T12:00:00Z",
		"rekor_uuid":   "rekor-uuid-xyz",
	}
	for k, v := range want {
		if c.inputs[k] != v {
			t.Errorf("inputs[%q] = %q; want %q", k, c.inputs[k], v)
		}
	}
}

func TestWorkflowDispatch_FailureFailsClosed(t *testing.T) {
	ti := newTestIssuer(t); defer ti.close()
	rekor := &fakeRekor{returnUUID: "uuid-1"}
	gh := &fakeGitHub{returnErr: errors.New("github API 502")}
	tok := ti.signTokenWithRepository(t, "coreyleavitt/sample")
	rec := doRequest(t,
		NewRouterWithDeps(fullDeps(t, ti, rekor, gh)),
		bodyForRepo("https://github.com/coreyleavitt/sample"),
		"Bearer "+tok)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502 when workflow_dispatch fails; got %d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("workflow_dispatch_failed")) {
		t.Fatalf("502 body should mention workflow_dispatch_failed; got %s", rec.Body.String())
	}
}
