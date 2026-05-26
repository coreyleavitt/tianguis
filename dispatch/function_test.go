package function

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"strings"
	"testing"
)

// genTestPEM produces a fresh PKCS#1 RSA private key PEM-encoded as a
// string — matches the format GitHub gives you when you generate an App
// private key in the GUI.
func genTestPEM(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	block := &pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	}
	return string(pem.EncodeToMemory(block))
}

func envFromMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestBuildDeps_HappyPath(t *testing.T) {
	pemStr := genTestPEM(t)
	env := envFromMap(map[string]string{
		"TIANGUIS_APP_ID":          "Iv23liHgJ5KyQ4o8b4Ka",
		"TIANGUIS_APP_PRIVATE_KEY": pemStr,
		"TIANGUIS_ISSUERS":         "github",
	})

	deps, err := buildDeps(env)
	if err != nil {
		t.Fatalf("buildDeps returned error on happy path: %v", err)
	}
	if deps.OIDC == nil {
		t.Errorf("expected OIDC verifier to be constructed")
	}
	if deps.GitHub == nil {
		t.Errorf("expected GitHub client to be constructed")
	}
}

func TestBuildDeps_MissingAppID(t *testing.T) {
	env := envFromMap(map[string]string{
		"TIANGUIS_APP_PRIVATE_KEY": genTestPEM(t),
	})
	_, err := buildDeps(env)
	if err == nil {
		t.Fatalf("expected error when TIANGUIS_APP_ID missing")
	}
	if !strings.Contains(err.Error(), "TIANGUIS_APP_ID") {
		t.Errorf("error should name the missing var: %v", err)
	}
}

func TestBuildDeps_MissingPrivateKey(t *testing.T) {
	env := envFromMap(map[string]string{
		"TIANGUIS_APP_ID": "Iv23liHgJ5KyQ4o8b4Ka",
	})
	_, err := buildDeps(env)
	if err == nil {
		t.Fatalf("expected error when TIANGUIS_APP_PRIVATE_KEY missing")
	}
	if !strings.Contains(err.Error(), "TIANGUIS_APP_PRIVATE_KEY") {
		t.Errorf("error should name the missing var: %v", err)
	}
}

func TestBuildDeps_MalformedPEM(t *testing.T) {
	env := envFromMap(map[string]string{
		"TIANGUIS_APP_ID":          "Iv23liHgJ5KyQ4o8b4Ka",
		"TIANGUIS_APP_PRIVATE_KEY": "not a real PEM, just garbage",
	})
	_, err := buildDeps(env)
	if err == nil {
		t.Fatalf("expected error on malformed PEM")
	}
}
