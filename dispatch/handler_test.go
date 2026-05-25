package function

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
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
		{"missing name", map[string]string{"oci_ref": "x", "provider": "github", "repo_url": "https://x"}},
		{"missing oci_ref", map[string]string{"name": "x", "provider": "github", "repo_url": "https://x"}},
		{"missing provider", map[string]string{"name": "x", "oci_ref": "x", "repo_url": "https://x"}},
		{"missing repo_url", map[string]string{"name": "x", "oci_ref": "x", "provider": "github"}},
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
