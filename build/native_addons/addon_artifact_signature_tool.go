// Command addon-artifact-signature-tool signs and verifies native add-on
// pushed-artifacts (the per-arch tarball or bare binary) with the ServiceRadar
// agent release ed25519 key (issue 3425, add-native-addon-build-signing §2.2).
//
// The agent verifies a pushed-artifact with verifyAddonArtifactSignature ->
// ed25519.Verify(releasePublicKey, rawArtifactBytes, signature), reusing the
// existing agent release trust root (SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY). This
// tool produces exactly that: a raw ed25519 signature over the artifact bytes,
// emitted hex-encoded (which the agent's decodeReleaseSignature accepts), so the
// build pipeline can sign each per-arch tarball and the control plane can record
// the value as the AddonAssignment's artifact_signature.
//
// Keys are read from the environment and never committed:
//
//	SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY  (sign)   ed25519 private key or 32-byte seed
//	SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY   (verify) ed25519 public key
//
// Both accept the same hex-or-base64 encodings the agent accepts. The private
// value may be a full 64-byte ed25519 private key or a 32-byte seed.
//
// Usage:
//
//	addon-artifact-signature-tool sign   --artifact <path> [--out <path>]
//	addon-artifact-signature-tool verify --artifact <path> --signature <hex|base64|@file>
//	addon-artifact-signature-tool public-key
//
// Exit codes: 0 success; 1 signing/verification failure; 2 usage/I-O error.
package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

const (
	privateKeyEnv = "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY"
	publicKeyEnv  = "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
)

var (
	errUsage              = errors.New("usage")
	errArtifactRequired   = errors.New("--artifact is required")
	errSignatureRequired  = errors.New("--signature is required")
	errPrivateKeyUnset    = errors.New(privateKeyEnv + " is not set")
	errPublicKeyUnset     = errors.New(publicKeyEnv + " is not set")
	errPrivateKeyLength   = errors.New("release private key must decode to an ed25519 private key (64 bytes) or seed (32 bytes)")
	errPublicKeyLength    = errors.New("release public key must decode to 32 bytes")
	errSignatureLength    = errors.New("signature must decode to 64 bytes")
	errEncoding           = errors.New("value is not valid hex or base64")
	errVerificationFailed = errors.New("signature verification failed")
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "%s: %s <sign|verify|public-key> [args]\n", errUsage, toolName())
		return 2
	}
	var err error
	switch args[0] {
	case "sign":
		err = runSign(args[1:], stdout)
	case "verify":
		err = runVerify(args[1:])
	case "public-key":
		err = runPublicKey(stdout)
	default:
		fmt.Fprintf(stderr, "%s: unknown subcommand %q\n", errUsage, args[0])
		return 2
	}
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		if errors.Is(err, errUsage) {
			return 2
		}
		return 1
	}
	return 0
}

func toolName() string {
	if len(os.Args) > 0 {
		return os.Args[0]
	}
	return "addon-artifact-signature-tool"
}

func runSign(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("sign", flag.ContinueOnError)
	artifactPath := fs.String("artifact", "", "path to the artifact to sign (per-arch tarball or bare binary)")
	outPath := fs.String("out", "", "optional path to write the hex signature (default: stdout)")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return errors.Join(errUsage, err)
	}
	if strings.TrimSpace(*artifactPath) == "" {
		return errArtifactRequired
	}

	priv, err := privateKey()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(*artifactPath)
	if err != nil {
		return err
	}

	sig := hex.EncodeToString(ed25519.Sign(priv, data))
	if strings.TrimSpace(*outPath) != "" {
		return os.WriteFile(*outPath, []byte(sig+"\n"), 0o644)
	}
	fmt.Fprintln(stdout, sig)
	return nil
}

func runVerify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	artifactPath := fs.String("artifact", "", "path to the artifact to verify")
	signature := fs.String("signature", "", "signature as hex/base64, or @file to read it from a file")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return errors.Join(errUsage, err)
	}
	if strings.TrimSpace(*artifactPath) == "" {
		return errArtifactRequired
	}
	if strings.TrimSpace(*signature) == "" {
		return errSignatureRequired
	}

	pub, err := publicKey()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(*artifactPath)
	if err != nil {
		return err
	}

	sigValue := *signature
	if path, ok := strings.CutPrefix(sigValue, "@"); ok {
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		sigValue = string(raw)
	}
	sig, err := decodeKeyOrSignature(sigValue)
	if err != nil {
		return err
	}
	if len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("%w: got %d", errSignatureLength, len(sig))
	}
	if !ed25519.Verify(pub, data, sig) {
		return errVerificationFailed
	}
	return nil
}

func runPublicKey(stdout io.Writer) error {
	// Prefer the configured public key; otherwise derive it from the private key.
	if raw := strings.TrimSpace(os.Getenv(publicKeyEnv)); raw != "" {
		pub, err := publicKey()
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, hex.EncodeToString(pub))
		return nil
	}
	priv, err := privateKey()
	if err != nil {
		return err
	}
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		return errPrivateKeyLength
	}
	fmt.Fprintln(stdout, hex.EncodeToString(pub))
	return nil
}

func privateKey() (ed25519.PrivateKey, error) {
	raw := strings.TrimSpace(os.Getenv(privateKeyEnv))
	if raw == "" {
		return nil, errPrivateKeyUnset
	}
	decoded, err := decodeKeyOrSignature(raw)
	if err != nil {
		return nil, fmt.Errorf("decode release private key: %w", err)
	}
	switch len(decoded) {
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(decoded), nil
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(decoded), nil
	default:
		return nil, fmt.Errorf("%w: got %d", errPrivateKeyLength, len(decoded))
	}
}

func publicKey() (ed25519.PublicKey, error) {
	raw := strings.TrimSpace(os.Getenv(publicKeyEnv))
	if raw == "" {
		return nil, errPublicKeyUnset
	}
	decoded, err := decodeKeyOrSignature(raw)
	if err != nil {
		return nil, fmt.Errorf("decode release public key: %w", err)
	}
	if len(decoded) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: got %d", errPublicKeyLength, len(decoded))
	}
	return ed25519.PublicKey(decoded), nil
}

// decodeKeyOrSignature mirrors the agent's decodeReleaseSignature: try hex first,
// then the four base64 variants. Keeping the accepted encodings identical to the
// agent guarantees a signature this tool emits is one the agent can decode.
func decodeKeyOrSignature(value string) ([]byte, error) {
	clean := strings.TrimSpace(value)
	if clean == "" {
		return nil, errEncoding
	}
	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if decoded, err := enc.DecodeString(clean); err == nil {
			return decoded, nil
		}
	}
	return nil, errEncoding
}
