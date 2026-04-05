package main

import (
	"archive/zip"
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	signatureAlgorithm = "ed25519"

	uploadSigningPrivateKeyEnv     = "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY"
	uploadSigningPrivateKeyFileEnv = "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE"
	uploadSigningPublicKeyEnv      = "PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY"
	uploadSigningPublicKeyFileEnv  = "PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY_FILE"
	uploadSigningKeyIDEnv          = "PLUGIN_UPLOAD_SIGNING_KEY_ID"
	uploadSigningSignerEnv         = "PLUGIN_UPLOAD_SIGNING_SIGNER"
)

var (
	errSigningKeyMissing     = errors.New("upload signing key is not configured")
	errSigningKeyInvalid     = errors.New("upload signing key is invalid")
	errPublicKeyMissing      = errors.New("upload signing public key is not configured")
	errPublicKeyInvalid      = errors.New("upload signing public key is invalid")
	errSigningKeyIDMissing   = errors.New("upload signing key id is not configured")
	errPluginManifestMissing = errors.New("plugin.yaml entry is missing")
	errPluginWASMMissing     = errors.New("plugin.wasm entry is missing")
)

type bundleMetadata struct {
	Entries                  []bundleEntry `json:"entries"`
	UploadSignatureMediaType string        `json:"upload_signature_media_type"`
}

type bundleEntry struct {
	ArchivePath string `json:"archive_path"`
	SourcePath  string `json:"source_path"`
}

type uploadSignature struct {
	Algorithm   string `json:"algorithm"`
	KeyID       string `json:"key_id"`
	Signer      string `json:"signer,omitempty"`
	ContentHash string `json:"content_hash"`
	Signature   string `json:"signature"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: %s <sign|verify|public-key> [args]", filepath.Base(os.Args[0]))
	}

	switch args[0] {
	case "sign":
		return runSign(args[1:])
	case "verify":
		return runVerify(args[1:])
	case "public-key":
		return runPublicKey(args[1:])
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runSign(args []string) error {
	fs := flag.NewFlagSet("sign", flag.ContinueOnError)
	metadataPath := fs.String("metadata", "", "path to bundle metadata json")
	outputPath := fs.String("out", "", "path to write upload signature json")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*metadataPath) == "" {
		return errors.New("--metadata is required")
	}
	if strings.TrimSpace(*outputPath) == "" {
		return errors.New("--out is required")
	}

	manifestBytes, wasmBytes, err := readBundleSourcesFromMetadata(*metadataPath)
	if err != nil {
		return err
	}
	signatureDoc, err := buildUploadSignature(manifestBytes, wasmBytes)
	if err != nil {
		return err
	}

	payload, err := json.MarshalIndent(signatureDoc, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(*outputPath, append(payload, '\n'), 0o644)
}

func runVerify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	bundlePath := fs.String("bundle", "", "path to bundle zip")
	signaturePath := fs.String("signature", "", "path to upload signature json")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*bundlePath) == "" {
		return errors.New("--bundle is required")
	}
	if strings.TrimSpace(*signaturePath) == "" {
		return errors.New("--signature is required")
	}

	manifestBytes, wasmBytes, err := readBundleSourcesFromArchive(*bundlePath)
	if err != nil {
		return err
	}

	signatureDoc, err := readSignature(*signaturePath)
	if err != nil {
		return err
	}

	if strings.TrimSpace(signatureDoc.Algorithm) != signatureAlgorithm {
		return fmt.Errorf("unsupported signature algorithm %q", signatureDoc.Algorithm)
	}

	if configuredKeyID := strings.TrimSpace(os.Getenv(uploadSigningKeyIDEnv)); configuredKeyID != "" &&
		signatureDoc.KeyID != configuredKeyID {
		return fmt.Errorf("signature key_id %q does not match configured key id %q", signatureDoc.KeyID, configuredKeyID)
	}

	contentHash := sha256BytesHex(wasmBytes)
	if normalizeHash(signatureDoc.ContentHash) != contentHash {
		return fmt.Errorf("content hash mismatch: signature has %s, bundle has %s", signatureDoc.ContentHash, contentHash)
	}

	canonicalPayload, err := buildVerificationPayload(manifestBytes, contentHash)
	if err != nil {
		return err
	}

	publicKey, err := uploadSigningPublicKey()
	if err != nil {
		return err
	}

	signatureValue, err := decodeSigningValue(signatureDoc.Signature)
	if err != nil {
		return err
	}
	if len(signatureValue) != ed25519.SignatureSize {
		return fmt.Errorf("signature length invalid: expected %d bytes, got %d", ed25519.SignatureSize, len(signatureValue))
	}

	if !ed25519.Verify(publicKey, canonicalPayload, signatureValue) {
		return errors.New("upload signature verification failed")
	}

	return nil
}

func runPublicKey(args []string) error {
	fs := flag.NewFlagSet("public-key", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return err
	}

	publicKey, err := uploadSigningPublicKey()
	if err != nil {
		privateKey, privateErr := uploadSigningPrivateKey()
		if privateErr != nil {
			return err
		}
		publicKey = privateKey.Public().(ed25519.PublicKey)
	}

	fmt.Println(base64.StdEncoding.EncodeToString(publicKey))
	return nil
}

func buildUploadSignature(manifestBytes, wasmBytes []byte) (uploadSignature, error) {
	contentHash := sha256BytesHex(wasmBytes)
	canonicalPayload, err := buildVerificationPayload(manifestBytes, contentHash)
	if err != nil {
		return uploadSignature{}, err
	}

	privateKey, err := uploadSigningPrivateKey()
	if err != nil {
		return uploadSignature{}, err
	}

	keyID := strings.TrimSpace(os.Getenv(uploadSigningKeyIDEnv))
	if keyID == "" {
		return uploadSignature{}, errSigningKeyIDMissing
	}

	signer := strings.TrimSpace(os.Getenv(uploadSigningSignerEnv))
	if signer == "" {
		signer = keyID
	}

	signatureValue := ed25519.Sign(privateKey, canonicalPayload)
	return uploadSignature{
		Algorithm:   signatureAlgorithm,
		KeyID:       keyID,
		Signer:      signer,
		ContentHash: contentHash,
		Signature:   base64.StdEncoding.EncodeToString(signatureValue),
	}, nil
}

func buildVerificationPayload(manifestBytes []byte, contentHash string) ([]byte, error) {
	manifest, err := parseManifest(manifestBytes)
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"content_hash": normalizeHash(contentHash),
		"manifest":     manifest,
	}
	return json.Marshal(payload)
}

func parseManifest(manifestBytes []byte) (map[string]any, error) {
	var manifest any
	if err := yaml.Unmarshal(manifestBytes, &manifest); err != nil {
		return nil, err
	}

	normalized, err := canonicalizeValue(manifest)
	if err != nil {
		return nil, err
	}
	manifestMap, ok := normalized.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("plugin manifest must decode to a map, got %T", normalized)
	}
	return manifestMap, nil
}

func canonicalizeValue(value any) (any, error) {
	switch typed := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, child := range typed {
			normalizedChild, err := canonicalizeValue(child)
			if err != nil {
				return nil, err
			}
			out[key] = normalizedChild
		}
		return out, nil
	case map[any]any:
		out := make(map[string]any, len(typed))
		for key, child := range typed {
			normalizedChild, err := canonicalizeValue(child)
			if err != nil {
				return nil, err
			}
			out[fmt.Sprint(key)] = normalizedChild
		}
		return out, nil
	case []any:
		out := make([]any, len(typed))
		for i, child := range typed {
			normalizedChild, err := canonicalizeValue(child)
			if err != nil {
				return nil, err
			}
			out[i] = normalizedChild
		}
		return out, nil
	default:
		return typed, nil
	}
}

func readBundleSourcesFromMetadata(metadataPath string) ([]byte, []byte, error) {
	data, err := os.ReadFile(metadataPath)
	if err != nil {
		return nil, nil, err
	}

	var metadata bundleMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return nil, nil, err
	}

	manifestPath := ""
	wasmPath := ""
	for _, entry := range metadata.Entries {
		switch entry.ArchivePath {
		case "plugin.yaml":
			manifestPath = entry.SourcePath
		case "plugin.wasm":
			wasmPath = entry.SourcePath
		}
	}

	if manifestPath == "" {
		return nil, nil, errPluginManifestMissing
	}
	if wasmPath == "" {
		return nil, nil, errPluginWASMMissing
	}

	manifestBytes, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, nil, err
	}
	wasmBytes, err := os.ReadFile(wasmPath)
	if err != nil {
		return nil, nil, err
	}

	return manifestBytes, wasmBytes, nil
}

func readBundleSourcesFromArchive(bundlePath string) ([]byte, []byte, error) {
	archive, err := zip.OpenReader(bundlePath)
	if err != nil {
		return nil, nil, err
	}
	defer archive.Close()

	var manifestBytes []byte
	var wasmBytes []byte
	for _, file := range archive.File {
		switch file.Name {
		case "plugin.yaml":
			manifestBytes, err = readZipFile(file)
			if err != nil {
				return nil, nil, err
			}
		case "plugin.wasm":
			wasmBytes, err = readZipFile(file)
			if err != nil {
				return nil, nil, err
			}
		}
	}

	if len(manifestBytes) == 0 {
		return nil, nil, errPluginManifestMissing
	}
	if len(wasmBytes) == 0 {
		return nil, nil, errPluginWASMMissing
	}
	return manifestBytes, wasmBytes, nil
}

func readZipFile(file *zip.File) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return io.ReadAll(reader)
}

func readSignature(signaturePath string) (uploadSignature, error) {
	data, err := os.ReadFile(signaturePath)
	if err != nil {
		return uploadSignature{}, err
	}
	var signatureDoc uploadSignature
	if err := json.Unmarshal(data, &signatureDoc); err != nil {
		return uploadSignature{}, err
	}
	return signatureDoc, nil
}

func uploadSigningPrivateKey() (ed25519.PrivateKey, error) {
	keyValue := strings.TrimSpace(os.Getenv(uploadSigningPrivateKeyEnv))
	if keyValue == "" {
		keyFile := strings.TrimSpace(os.Getenv(uploadSigningPrivateKeyFileEnv))
		if keyFile != "" {
			content, err := os.ReadFile(keyFile)
			if err != nil {
				return nil, err
			}
			keyValue = strings.TrimSpace(string(content))
		}
	}
	if keyValue == "" {
		return nil, errSigningKeyMissing
	}

	keyBytes, err := decodeSigningValue(keyValue)
	if err != nil {
		return nil, err
	}
	switch len(keyBytes) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(keyBytes), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(keyBytes), nil
	default:
		return nil, fmt.Errorf("%w: expected %d or %d bytes, got %d", errSigningKeyInvalid, ed25519.SeedSize, ed25519.PrivateKeySize, len(keyBytes))
	}
}

func uploadSigningPublicKey() (ed25519.PublicKey, error) {
	keyValue := strings.TrimSpace(os.Getenv(uploadSigningPublicKeyEnv))
	if keyValue == "" {
		keyFile := strings.TrimSpace(os.Getenv(uploadSigningPublicKeyFileEnv))
		if keyFile != "" {
			content, err := os.ReadFile(keyFile)
			if err != nil {
				return nil, err
			}
			keyValue = strings.TrimSpace(string(content))
		}
	}
	if keyValue == "" {
		privateKey, err := uploadSigningPrivateKey()
		if err != nil {
			return nil, errPublicKeyMissing
		}
		return privateKey.Public().(ed25519.PublicKey), nil
	}

	keyBytes, err := decodeSigningValue(keyValue)
	if err != nil {
		return nil, err
	}
	if len(keyBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: expected %d bytes, got %d", errPublicKeyInvalid, ed25519.PublicKeySize, len(keyBytes))
	}
	return ed25519.PublicKey(keyBytes), nil
}

func decodeSigningValue(value string) ([]byte, error) {
	clean := strings.TrimSpace(value)
	if clean == "" {
		return nil, errSigningKeyInvalid
	}
	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}
	for _, encoding := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if decoded, err := encoding.DecodeString(clean); err == nil {
			return decoded, nil
		}
	}
	return nil, errSigningKeyInvalid
}

func sha256BytesHex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func normalizeHash(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func mustMarshalSignatureForTest(sig uploadSignature) []byte {
	data, err := json.Marshal(sig)
	if err != nil {
		panic(err)
	}
	return data
}

func compactJSONForTest(data []byte) []byte {
	var out bytes.Buffer
	if err := json.Compact(&out, data); err != nil {
		panic(err)
	}
	return out.Bytes()
}
