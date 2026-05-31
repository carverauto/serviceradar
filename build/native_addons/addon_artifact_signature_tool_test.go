package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newKeyEnv generates a throwaway ed25519 keypair and sets the release key env
// vars the tool reads, returning the private seed + the hex public key.
func newKeyEnv(t *testing.T) (priv ed25519.PrivateKey, pubHex string) {
	t.Helper()
	pub, p, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	pubHex = hex.EncodeToString(pub)
	t.Setenv(privateKeyEnv, hex.EncodeToString(p.Seed()))
	t.Setenv(publicKeyEnv, pubHex)
	return p, pubHex
}

func writeFile(t *testing.T, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func TestSignVerifyRoundTripMatchesAgentContract(t *testing.T) {
	priv, _ := newKeyEnv(t)
	artifact := []byte("per-arch netprobe tarball bytes \x00\x01\x02")
	artifactPath := writeFile(t, "artifact.tar.gz", artifact)

	var out bytes.Buffer
	if err := runSign([]string{"--artifact", artifactPath}, &out); err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig := strings.TrimSpace(out.String())

	// The signature must be a 64-byte ed25519 signature, hex-encoded.
	rawSig, err := hex.DecodeString(sig)
	if err != nil {
		t.Fatalf("signature is not hex: %v", err)
	}
	if len(rawSig) != ed25519.SignatureSize {
		t.Fatalf("signature length = %d, want %d", len(rawSig), ed25519.SignatureSize)
	}

	// Exactly the agent's check: ed25519.Verify(releasePublicKey, rawBytes, sig).
	if !ed25519.Verify(priv.Public().(ed25519.PublicKey), artifact, rawSig) {
		t.Fatal("agent-equivalent ed25519.Verify rejected the signature")
	}

	// And the tool's own verify accepts it (hex).
	if err := runVerify([]string{"--artifact", artifactPath, "--signature", sig}); err != nil {
		t.Fatalf("verify(hex): %v", err)
	}

	// The agent also accepts base64; the tool must too.
	b64 := base64.StdEncoding.EncodeToString(rawSig)
	if err := runVerify([]string{"--artifact", artifactPath, "--signature", b64}); err != nil {
		t.Fatalf("verify(base64): %v", err)
	}
}

func TestVerifyRejectsTamperAndWrongKey(t *testing.T) {
	newKeyEnv(t)
	artifactPath := writeFile(t, "a.bin", bytes.Repeat([]byte{0xab}, 256))
	var out bytes.Buffer
	if err := runSign([]string{"--artifact", artifactPath}, &out); err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig := strings.TrimSpace(out.String())

	tampered := writeFile(t, "tampered.bin", append(bytes.Repeat([]byte{0xab}, 255), 0x00))
	if err := runVerify([]string{"--artifact", tampered, "--signature", sig}); err == nil {
		t.Fatal("verify accepted a tampered artifact")
	}

	// Different public key must reject the signature.
	otherPub, _, _ := ed25519.GenerateKey(nil)
	t.Setenv(publicKeyEnv, hex.EncodeToString(otherPub))
	if err := runVerify([]string{"--artifact", artifactPath, "--signature", sig}); err == nil {
		t.Fatal("verify accepted a signature under the wrong key")
	}
}

func TestPrivateKeyAcceptsSeedAndFullKey(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)

	t.Setenv(privateKeyEnv, hex.EncodeToString(priv.Seed()))
	fromSeed, err := privateKey()
	if err != nil {
		t.Fatalf("seed key: %v", err)
	}
	t.Setenv(privateKeyEnv, hex.EncodeToString(priv))
	fromFull, err := privateKey()
	if err != nil {
		t.Fatalf("full key: %v", err)
	}
	if !fromSeed.Equal(fromFull) || !fromFull.Public().(ed25519.PublicKey).Equal(pub) {
		t.Fatal("seed and full key did not resolve to the same keypair")
	}
}

func TestPublicKeyDerivesFromPrivateWhenUnset(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	t.Setenv(privateKeyEnv, hex.EncodeToString(priv.Seed()))
	os.Unsetenv(publicKeyEnv)

	var out bytes.Buffer
	if err := runPublicKey(&out); err != nil {
		t.Fatalf("public-key: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != hex.EncodeToString(pub) {
		t.Fatalf("derived public key = %s, want %s", got, hex.EncodeToString(pub))
	}
}

func TestSignFailsWhenKeyUnset(t *testing.T) {
	os.Unsetenv(privateKeyEnv)
	artifactPath := writeFile(t, "a.bin", []byte("x"))
	if err := runSign([]string{"--artifact", artifactPath}, &bytes.Buffer{}); err == nil {
		t.Fatal("sign succeeded without a private key")
	}
}

func TestDecodeKeyOrSignatureEncodings(t *testing.T) {
	want := bytes.Repeat([]byte{0x5a}, 32)
	for name, encoded := range map[string]string{
		"hex":     hex.EncodeToString(want),
		"std-b64": base64.StdEncoding.EncodeToString(want),
		"rawstd":  base64.RawStdEncoding.EncodeToString(want),
		"url-b64": base64.URLEncoding.EncodeToString(want),
		"rawurl":  base64.RawURLEncoding.EncodeToString(want),
	} {
		got, err := decodeKeyOrSignature(encoded)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("%s: decode = %x, %v", name, got, err)
		}
	}
	if _, err := decodeKeyOrSignature("not valid!!"); err == nil {
		t.Fatal("expected error for invalid encoding")
	}
}
