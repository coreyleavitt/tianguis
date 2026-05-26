package function

// Scaleway Functions Go runtime entry point. Scaleway compiles this
// package and generates its own main wrapper that calls Handle per
// request — so this package MUST NOT be `main` and MUST NOT define
// its own main().
//
// For local development, see cmd/server/main.go in this module, which
// imports this package and runs the same handler via http.ListenAndServe.

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// Handle is invoked per request by the Scaleway runtime.
func Handle(w http.ResponseWriter, r *http.Request) {
	scalewayHandler().ServeHTTP(w, r)
}

var (
	handlerOnce sync.Once
	handlerMu   http.Handler
)

func scalewayHandler() http.Handler {
	handlerOnce.Do(func() {
		deps, err := buildDeps(os.Getenv)
		if err != nil {
			log.Fatalf("dispatch boot failed: %v", err)
		}
		handlerMu = NewRouterWithDeps(deps)
	})
	return handlerMu
}

// buildDeps reads required configuration from `env` and returns a wired
// Dependencies struct. Fail-fast on missing or malformed config — a half-
// configured dispatch is more dangerous than a non-running one.
//
// Separated from scalewayHandler so it's directly testable without
// touching sync.Once or actually serving HTTP. See function_test.go.
func buildDeps(env func(string) string) (Dependencies, error) {
	appID := env("TIANGUIS_APP_ID")
	if appID == "" {
		return Dependencies{}, errors.New("TIANGUIS_APP_ID is required")
	}
	keyPEM := env("TIANGUIS_APP_PRIVATE_KEY")
	if keyPEM == "" {
		return Dependencies{}, errors.New("TIANGUIS_APP_PRIVATE_KEY is required")
	}
	block, _ := pem.Decode([]byte(keyPEM))
	if block == nil {
		return Dependencies{}, errors.New("TIANGUIS_APP_PRIVATE_KEY is not valid PEM")
	}
	key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return Dependencies{}, errors.New("TIANGUIS_APP_PRIVATE_KEY parse failed: " + err.Error())
	}

	verifier := NewMultiIssuerVerifier(context.Background(), issuerConfigsFrom(env))
	return Dependencies{
		OIDC:   verifier,
		GitHub: NewGitHubAppClient(appID, key),
	}, nil
}

// NewLocalHandler is exported so cmd/server/main.go can run the same
// handler locally via http.ListenAndServe. Construction is identical
// to Handle's lazy-init path.
func NewLocalHandler() http.Handler {
	return scalewayHandler()
}

// issuerConfigs reads the trusted OIDC issuer set from env. Format:
//
//	TIANGUIS_ISSUERS=github,gitlab
//
// Each name maps to a built-in config below. Adding a new provider
// means adding to issuerCatalog and (in #5) any per-provider repo-
// ownership-check logic.
func issuerConfigs() []IssuerConfig {
	return issuerConfigsFrom(os.Getenv)
}

func issuerConfigsFrom(env func(string) string) []IssuerConfig {
	names := env("TIANGUIS_ISSUERS")
	if names == "" {
		// Sensible default: trust GitHub Actions + GitLab CI out of the box.
		names = "github,gitlab"
	}
	var out []IssuerConfig
	for _, n := range strings.Split(names, ",") {
		n = strings.TrimSpace(n)
		if cfg, ok := issuerCatalog[n]; ok {
			out = append(out, cfg)
		} else {
			log.Printf("warning: unknown issuer %q in TIANGUIS_ISSUERS, skipping", n)
		}
	}
	return out
}

// issuerCatalog is the curated list of supported OIDC providers.
// The aud "sigstore" is the standard audience used by cosign keyless;
// reusing it means authors don't have to mint a second token just for
// the dispatch call.
var issuerCatalog = map[string]IssuerConfig{
	"github": {
		Name:      "github",
		URL:       "https://token.actions.githubusercontent.com",
		JWKSURL:   "https://token.actions.githubusercontent.com/.well-known/jwks",
		Audiences: []string{"sigstore"},
	},
	"gitlab": {
		Name:      "gitlab",
		URL:       "https://gitlab.com",
		JWKSURL:   "https://gitlab.com/oauth/discovery/keys",
		Audiences: []string{"sigstore"},
	},
}
