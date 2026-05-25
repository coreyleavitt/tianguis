// Package dispatch — OIDC bearer-token verification for the tianguis
// publish endpoint. Multi-issuer: each issuer is configured with its
// well-known URL, JWKS URL, and accepted audiences. Verification is
// real cryptographic JWS signature check against the issuer's
// published keys.
package function

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// IssuerConfig declares one trusted OIDC issuer.
type IssuerConfig struct {
	Name      string   // human label: "github", "gitlab", ...
	URL       string   // issuer URL (must match the iss claim exactly)
	JWKSURL   string   // where to fetch the issuer's public keys
	Audiences []string // accepted aud values
}

// Claims is the subset of OIDC claims tianguis cares about. Issuer
// specifics (GitHub's "repository", GitLab's "project_path") get
// surfaced via the IssuerSpecific map for downstream identity checks.
type Claims struct {
	Issuer          string
	Subject         string
	Audience        []string
	Expiry          time.Time
	IssuerSpecific  map[string]any // raw claims for per-issuer post-checks (#5)
}

// OIDCVerifier authenticates a bearer token against the configured
// issuer set. Implementations MUST verify the signature against the
// issuer's published JWKS, the issuer/audience/expiry claims, and
// return Claims on success.
type OIDCVerifier interface {
	Verify(ctx context.Context, rawToken string) (*Claims, error)
}

// Verification errors are distinct types so handlers can map them to
// HTTP status codes (all → 401 for now, but the catalog leaves room
// for future expansion).
var (
	ErrMalformedToken  = errors.New("malformed bearer token")
	ErrUnknownIssuer   = errors.New("unknown issuer")
	ErrInvalidSignature = errors.New("invalid token signature")
	ErrTokenExpired    = errors.New("token expired")
	ErrInvalidAudience = errors.New("token audience not accepted")
)

// multiIssuerVerifier fetches each issuer's JWKS on demand and caches
// the parsed keyset in memory. The cache is process-local; a function
// cold start re-fetches. (Scaleway functions stay warm for minutes
// between invocations, so most requests hit the cache.)
type multiIssuerVerifier struct {
	configs []IssuerConfig
	mu      sync.Mutex
	cache   map[string]cachedKeys // keyed by JWKSURL
	http    *http.Client
}

type cachedKeys struct {
	keys    *jose.JSONWebKeySet
	fetched time.Time
}

const jwksCacheTTL = 10 * time.Minute

// NewMultiIssuerVerifier returns a verifier configured for the given
// issuers. The context is reserved for future warm-up; current
// implementation lazily fetches JWKS on first verify per issuer.
func NewMultiIssuerVerifier(_ context.Context, configs []IssuerConfig) OIDCVerifier {
	return &multiIssuerVerifier{
		configs: configs,
		cache:   make(map[string]cachedKeys),
		http:    &http.Client{Timeout: 5 * time.Second},
	}
}

func (v *multiIssuerVerifier) Verify(ctx context.Context, rawToken string) (*Claims, error) {
	// Parse JWS (signature is verified separately once we know the issuer's keys).
	signedAcceptedAlgorithms := []jose.SignatureAlgorithm{jose.RS256, jose.ES256}
	parsed, err := jwt.ParseSigned(rawToken, signedAcceptedAlgorithms)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformedToken, err)
	}

	// Peek at standard claims (UnsafeClaimsWithoutVerification just deserializes;
	// signature is verified in the next step).
	var unverified jwt.Claims
	if err := parsed.UnsafeClaimsWithoutVerification(&unverified); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformedToken, err)
	}

	// Match issuer to a configured one.
	var matched *IssuerConfig
	for i := range v.configs {
		if v.configs[i].URL == unverified.Issuer {
			matched = &v.configs[i]
			break
		}
	}
	if matched == nil {
		return nil, fmt.Errorf("%w: iss=%q", ErrUnknownIssuer, unverified.Issuer)
	}

	// Fetch / cache the issuer's JWKS.
	keys, err := v.fetchKeys(ctx, matched.JWKSURL)
	if err != nil {
		return nil, fmt.Errorf("fetch JWKS: %w", err)
	}

	// Verify signature against published keys, deserialize claims.
	var verifiedStd jwt.Claims
	var raw map[string]any
	if err := parsed.Claims(keys, &verifiedStd, &raw); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidSignature, err)
	}

	// Expiry check.
	if !verifiedStd.Expiry.Time().After(time.Now()) {
		return nil, ErrTokenExpired
	}

	// Audience check — at least one matching aud.
	if !audienceMatches(verifiedStd.Audience, matched.Audiences) {
		return nil, fmt.Errorf("%w: got=%v want=%v",
			ErrInvalidAudience, []string(verifiedStd.Audience), matched.Audiences)
	}

	return &Claims{
		Issuer:         verifiedStd.Issuer,
		Subject:        verifiedStd.Subject,
		Audience:       []string(verifiedStd.Audience),
		Expiry:         verifiedStd.Expiry.Time(),
		IssuerSpecific: raw,
	}, nil
}

func (v *multiIssuerVerifier) fetchKeys(ctx context.Context, jwksURL string) (*jose.JSONWebKeySet, error) {
	v.mu.Lock()
	cached, ok := v.cache[jwksURL]
	v.mu.Unlock()
	if ok && time.Since(cached.fetched) < jwksCacheTTL {
		return cached.keys, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, jwksURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := v.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("JWKS endpoint %s returned %d", jwksURL, resp.StatusCode)
	}
	var keys jose.JSONWebKeySet
	if err := json.NewDecoder(resp.Body).Decode(&keys); err != nil {
		return nil, err
	}

	v.mu.Lock()
	v.cache[jwksURL] = cachedKeys{keys: &keys, fetched: time.Now()}
	v.mu.Unlock()
	return &keys, nil
}

func audienceMatches(got, accepted []string) bool {
	for _, g := range got {
		for _, a := range accepted {
			if g == a {
				return true
			}
		}
	}
	return false
}
