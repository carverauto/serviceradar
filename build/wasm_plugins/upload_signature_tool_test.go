package main

import (
	"archive/zip"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildAndVerifyUploadSignature(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}

	t.Setenv(uploadSigningPrivateKeyEnv, base64.StdEncoding.EncodeToString(privateKey))
	t.Setenv(uploadSigningKeyIDEnv, "first-party")
	t.Setenv(uploadSigningSignerEnv, "serviceradar-release")
	t.Setenv(uploadSigningPublicKeyEnv, base64.StdEncoding.EncodeToString(publicKey))

	manifest := []byte("id: demo-plugin\nname: Demo Plugin\nversion: 1.0.0\nentrypoint: run_check\nruntime: wasi-preview1\noutputs: serviceradar.plugin_result.v1\ncapabilities:\n  - log\nresources:\n  requested_memory_mb: 16\n  requested_cpu_ms: 250\n  max_open_connections: 0\n")
	wasm := []byte("\x00asm\x01\x00\x00\x00")

	signatureDoc, err := buildUploadSignature(manifest, wasm)
	if err != nil {
		t.Fatalf("buildUploadSignature() error = %v", err)
	}

	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.zip")
	signaturePath := filepath.Join(tmpDir, "upload-signature.json")
	if err := writeBundleForTest(bundlePath, manifest, wasm); err != nil {
		t.Fatalf("writeBundleForTest() error = %v", err)
	}
	if err := os.WriteFile(signaturePath, mustMarshalSignatureForTest(signatureDoc), 0o644); err != nil {
		t.Fatalf("WriteFile(signature) error = %v", err)
	}

	if err := run([]string{"verify", "--bundle", bundlePath, "--signature", signaturePath}); err != nil {
		t.Fatalf("run(verify) error = %v", err)
	}
}

func TestRunSignUsesBundleArchive(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}

	t.Setenv(uploadSigningPrivateKeyEnv, base64.StdEncoding.EncodeToString(privateKey))
	t.Setenv(uploadSigningKeyIDEnv, "first-party")
	t.Setenv(uploadSigningSignerEnv, "serviceradar-release")
	t.Setenv(uploadSigningPublicKeyEnv, base64.StdEncoding.EncodeToString(publicKey))

	manifest := []byte("id: demo-plugin\nname: Demo Plugin\nversion: 1.0.0\nentrypoint: run_check\nruntime: wasi-preview1\noutputs: serviceradar.plugin_result.v1\ncapabilities:\n  - log\nresources:\n  requested_memory_mb: 16\n  requested_cpu_ms: 250\n  max_open_connections: 0\n")
	wasm := []byte("\x00asm\x01\x00\x00\x00")

	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.zip")
	signaturePath := filepath.Join(tmpDir, "upload-signature.json")
	if err := writeBundleForTest(bundlePath, manifest, wasm); err != nil {
		t.Fatalf("writeBundleForTest() error = %v", err)
	}

	if err := run([]string{"sign", "--bundle", bundlePath, "--out", signaturePath}); err != nil {
		t.Fatalf("run(sign) error = %v", err)
	}
	if err := run([]string{"verify", "--bundle", bundlePath, "--signature", signaturePath}); err != nil {
		t.Fatalf("run(verify) error = %v", err)
	}
}

func TestBuildAndVerifyUploadSignatureViaTransit(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}

	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/v1/transit/sign/plugin-upload-signing"):
			var body struct {
				Input string `json:"input"`
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			payload, err := base64.StdEncoding.DecodeString(body.Input)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			signature := ed25519.Sign(privateKey, payload)
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"data": map[string]string{
					"signature": "vault:v1:" + base64.StdEncoding.EncodeToString(signature),
				},
			})
		case request.Method == http.MethodGet && strings.HasSuffix(request.URL.Path, "/v1/transit/keys/plugin-upload-signing"):
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"data": map[string]any{
					"latest_version": 1,
					"keys": map[string]any{
						"1": map[string]any{
							"public_key": base64.StdEncoding.EncodeToString(publicKey),
						},
					},
				},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)

	t.Setenv(uploadSigningTransitKeyEnv, "plugin-upload-signing")
	t.Setenv("VAULT_ADDR", server.URL)
	t.Setenv("VAULT_TOKEN", "test-token")
	t.Setenv("VAULT_SKIP_VERIFY", "true")
	t.Setenv(uploadSigningPrivateKeyEnv, "")
	t.Setenv(uploadSigningKeyIDEnv, "serviceradar-first-party-v2")
	t.Setenv(uploadSigningSignerEnv, "serviceradar-release")
	t.Setenv(uploadSigningPublicKeyEnv, "")

	manifest := []byte("id: demo-plugin\nname: Demo Plugin\nversion: 1.0.0\nentrypoint: run_check\nruntime: wasi-preview1\noutputs: serviceradar.plugin_result.v1\ncapabilities:\n  - log\nresources:\n  requested_memory_mb: 16\n  requested_cpu_ms: 250\n  max_open_connections: 0\n")
	wasm := []byte("\x00asm\x01\x00\x00\x00")

	signatureDoc, err := buildUploadSignature(manifest, wasm)
	if err != nil {
		t.Fatalf("buildUploadSignature() error = %v", err)
	}
	if signatureDoc.KeyID != "serviceradar-first-party-v2" {
		t.Fatalf("key id = %q", signatureDoc.KeyID)
	}

	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.zip")
	signaturePath := filepath.Join(tmpDir, "upload-signature.json")
	if err := writeBundleForTest(bundlePath, manifest, wasm); err != nil {
		t.Fatalf("writeBundleForTest() error = %v", err)
	}
	if err := os.WriteFile(signaturePath, mustMarshalSignatureForTest(signatureDoc), 0o644); err != nil {
		t.Fatalf("WriteFile(signature) error = %v", err)
	}

	if err := run([]string{"verify", "--bundle", bundlePath, "--signature", signaturePath}); err != nil {
		t.Fatalf("run(verify) error = %v", err)
	}
}

func TestBuildVerificationPayloadCanonicalizesManifest(t *testing.T) {
	manifest := []byte("name: Demo\nid: demo-plugin\nnested:\n  z: 1\n  a: true\n")
	payload, err := buildVerificationPayload(manifest, "ABC123")
	if err != nil {
		t.Fatalf("buildVerificationPayload() error = %v", err)
	}

	want := `{"content_hash":"abc123","manifest":{"id":"demo-plugin","name":"Demo","nested":{"a":true,"z":1}}}`
	if string(compactJSONForTest(payload)) != want {
		t.Fatalf("payload = %s, want %s", payload, want)
	}
}

// TestBuildVerificationPayloadDoesNotHTMLEscape guards the byte-for-byte
// canonicalization contract with the Elixir first-party importer
// (ServiceRadarWebNG.Plugins.UploadSignature). Elixir's Jason encoder emits the
// bytes '<', '>' and '&' literally, while encoding/json HTML-escapes them by
// default. That divergence once broke awx-inventory-sync, whose description
// contains "agent -> gateway -> DIRE": the signer emitted the HTML escape for
// '>' where the Elixir verifier reproduced a literal '>', so ed25519
// verification failed with invalid_signature even though the manifest matched.
// The literal '<', '>' and '&' in want below assert HTML escaping stays off; if
// it regressed, the payload would contain the \u00XX escapes instead and this
// equality check would fail.
func TestBuildVerificationPayloadDoesNotHTMLEscape(t *testing.T) {
	manifest := []byte("id: demo-plugin\nname: Demo\ndescription: agent -> gateway & <core>\n")
	payload, err := buildVerificationPayload(manifest, "ABC123")
	if err != nil {
		t.Fatalf("buildVerificationPayload() error = %v", err)
	}

	want := `{"content_hash":"abc123","manifest":{"description":"agent -> gateway & <core>","id":"demo-plugin","name":"Demo"}}`
	if string(payload) != want {
		t.Fatalf("payload = %s, want %s", payload, want)
	}
}

func writeBundleForTest(path string, manifest, wasm []byte) (err error) {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); err == nil && closeErr != nil {
			err = closeErr
		}
	}()

	zipWriter := zip.NewWriter(file)
	if err := writeZipEntry(zipWriter, "plugin.yaml", manifest); err != nil {
		return err
	}
	if err := writeZipEntry(zipWriter, "plugin.wasm", wasm); err != nil {
		return err
	}
	return zipWriter.Close()
}

func writeZipEntry(zipWriter *zip.Writer, name string, data []byte) error {
	writer, err := zipWriter.Create(name)
	if err != nil {
		return err
	}
	_, err = writer.Write(data)
	return err
}
