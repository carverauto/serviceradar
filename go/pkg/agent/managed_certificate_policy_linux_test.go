package agent

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func signedManagedPolicy(t *testing.T, key ed25519.PrivateKey, snapshot managedCertificatePolicySnapshot) ManagedCertificatePolicyEnvelope {
	t.Helper()
	payload, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	return ManagedCertificatePolicyEnvelope{Payload: payload, Signature: ed25519.Sign(key, append([]byte("serviceradar.certificate-policy.v1\x00"), payload...))}
}

func TestManagedCertificatePolicyAuthenticatesAndPreservesActivePolicy(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	store := managedCertificatePolicyStore{path: filepath.Join(t.TempDir(), "policy.json"), key: public, now: func() time.Time { return now }}
	initial := managedCertificatePolicySnapshot{Version: 1, GeneratedAt: now, ValidUntil: now.Add(30 * time.Second), AllowedFingerprints: []string{strings.Repeat("a1", 32)}}
	payload := []byte(fmt.Sprintf(`{"version":1,"generated_at":%q,"valid_until":%q,"allowed_fingerprints":[%q],"nats_permissions":{%q:{"publish":["logs.syslog","$JS.API.STREAM.INFO.events"],"subscribe":["_INBOX.>"]}}}`, now.Format(time.RFC3339Nano), initial.ValidUntil.Format(time.RFC3339Nano), strings.Repeat("a1", 32), strings.Repeat("a1", 32)))
	envelope := ManagedCertificatePolicyEnvelope{Payload: payload, Signature: ed25519.Sign(private, append([]byte("serviceradar.certificate-policy.v1\x00"), payload...))}
	result, err := store.install(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Installed || !result.GeneratedAt.Equal(now) || !result.ValidUntil.Equal(initial.ValidUntil) {
		t.Fatalf("wrong installation receipt: %+v", result)
	}
	info, err := os.Stat(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0644 {
		t.Fatalf("receivers cannot read policy: mode=%o", info.Mode().Perm())
	}
	cases := map[string]func() ManagedCertificatePolicyEnvelope{
		"tampered-payload": func() ManagedCertificatePolicyEnvelope {
			copy := envelope
			copy.Payload = append([]byte(" "), copy.Payload...)
			return copy
		},
		"unsigned": func() ManagedCertificatePolicyEnvelope { copy := envelope; copy.Signature = nil; return copy },
		"wrong-authority": func() ManagedCertificatePolicyEnvelope {
			_, key, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			return signedManagedPolicy(t, key, initial)
		},
		"wrong-domain": func() ManagedCertificatePolicyEnvelope {
			copy := envelope
			copy.Signature = ed25519.Sign(private, copy.Payload)
			return copy
		},
	}
	for name, makeEnvelope := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := store.install(makeEnvelope()); err == nil {
				t.Fatal("accepted unauthenticated policy")
			}
			got, err := os.ReadFile(store.path)
			if err != nil || string(got) != string(envelope.Payload) {
				t.Fatal("rejected policy replaced the active file")
			}
		})
	}
}

func TestManagedCertificatePolicyRejectsInvalidLeases(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	store := managedCertificatePolicyStore{path: filepath.Join(t.TempDir(), "policy.json"), key: public, now: func() time.Time { return now }}
	base := managedCertificatePolicySnapshot{Version: 1, GeneratedAt: now, ValidUntil: now.Add(30 * time.Second), AllowedFingerprints: []string{strings.Repeat("12", 32)}}
	for name, change := range map[string]func(*managedCertificatePolicySnapshot){
		"expired": func(p *managedCertificatePolicySnapshot) {
			p.GeneratedAt = now.Add(-30 * time.Second)
			p.ValidUntil = now
		},
		"excess-lease": func(p *managedCertificatePolicySnapshot) { p.ValidUntil = now.Add(31 * time.Second) },
		"future": func(p *managedCertificatePolicySnapshot) {
			p.GeneratedAt = now.Add(6 * time.Second)
			p.ValidUntil = p.GeneratedAt.Add(30 * time.Second)
		},
		"reverse-time":          func(p *managedCertificatePolicySnapshot) { p.ValidUntil = now.Add(-time.Second) },
		"wrong-version":         func(p *managedCertificatePolicySnapshot) { p.Version = 2 },
		"uppercase-fingerprint": func(p *managedCertificatePolicySnapshot) { p.AllowedFingerprints = []string{strings.Repeat("AB", 32)} },
		"short-fingerprint":     func(p *managedCertificatePolicySnapshot) { p.AllowedFingerprints = []string{"abc"} },
		"nonhex-fingerprint":    func(p *managedCertificatePolicySnapshot) { p.AllowedFingerprints = []string{strings.Repeat("xy", 32)} },
		"permissions-outside-allowlist": func(p *managedCertificatePolicySnapshot) {
			p.NATSPermissions = map[string]managedCertificateNATSPermissions{strings.Repeat("ab", 32): {Publish: []string{"logs.syslog"}}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			snapshot := base
			change(&snapshot)
			if _, err := store.install(signedManagedPolicy(t, private, snapshot)); err == nil {
				t.Fatal("accepted invalid signed policy lease")
			}
			if _, err := os.Stat(store.path); !os.IsNotExist(err) {
				t.Fatal("invalid lease published a policy")
			}
		})
	}
	base.GeneratedAt = now.Add(5 * time.Second)
	base.ValidUntil = base.GeneratedAt.Add(30 * time.Second)
	if _, err := store.install(signedManagedPolicy(t, private, base)); err != nil {
		t.Fatalf("rejected permitted clock skew: %v", err)
	}
}

func TestManagedCertificatePolicyMonotonicAcrossRestart(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	store := managedCertificatePolicyStore{path: filepath.Join(t.TempDir(), "policy.json"), key: public, now: func() time.Time { return now }}
	first := managedCertificatePolicySnapshot{Version: 1, GeneratedAt: now, ValidUntil: now.Add(30 * time.Second), AllowedFingerprints: []string{strings.Repeat("ab", 32)}}
	old := signedManagedPolicy(t, private, first)
	if _, err := store.install(old); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Second)
	newer := managedCertificatePolicySnapshot{Version: 1, GeneratedAt: now, ValidUntil: now.Add(30 * time.Second), AllowedFingerprints: []string{}}
	current := signedManagedPolicy(t, private, newer)
	if _, err := store.install(current); err != nil {
		t.Fatal(err)
	}
	restarted := managedCertificatePolicyStore{path: store.path, key: public, now: func() time.Time { return now }}
	if _, err := restarted.install(current); err != nil {
		t.Fatalf("idempotent retry rejected: %v", err)
	}
	if _, err := restarted.install(old); err == nil {
		t.Fatal("replayed policy restored a removed fingerprint")
	}
	newer.AllowedFingerprints = first.AllowedFingerprints
	if _, err := restarted.install(signedManagedPolicy(t, private, newer)); err == nil {
		t.Fatal("same timestamp allowed a changed fingerprint set")
	}
	bytes, err := os.ReadFile(store.path)
	if err != nil || string(bytes) != string(current.Payload) {
		t.Fatal("replay altered persisted policy")
	}
	now = now.Add(31 * time.Second)
	if _, err := restarted.install(current); err == nil {
		t.Fatal("identical replay extended an expired lease")
	}
}
