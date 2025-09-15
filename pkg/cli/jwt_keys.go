package cli

import (
    "crypto/rand"
    "crypto/rsa"
    "crypto/sha256"
    "crypto/x509"
    "encoding/pem"
    "flag"
    "fmt"
)

// GenerateJWTKeysHandler handles flags for the generate-jwt-keys subcommand.
type GenerateJWTKeysHandler struct{}

// Parse processes arguments for generate-jwt-keys.
func (GenerateJWTKeysHandler) Parse(args []string, cfg *CmdConfig) error {
    fs := flag.NewFlagSet("generate-jwt-keys", flag.ExitOnError)
    file := fs.String("file", "/etc/serviceradar/config/core.json", "Path to core.json config")
    kid := fs.String("kid", "", "Key ID (kid) to embed in JWT header")
    bits := fs.Int("bits", 2048, "RSA key size in bits")
    force := fs.Bool("force", false, "Overwrite existing RS256 keys if present")
    if err := fs.Parse(args); err != nil {
        return fmt.Errorf("parsing generate-jwt-keys flags: %w", err)
    }
    cfg.ConfigFile = *file
    cfg.JWTKeyID = *kid
    cfg.JWTKeyBits = *bits
    cfg.JWTForce = *force

    return nil
}

// RunGenerateJWTKeys generates an RSA keypair and updates core.json auth config.
func RunGenerateJWTKeys(cfg *CmdConfig) error {
    if cfg.ConfigFile == "" {
        return fmt.Errorf("missing -file path to core.json")
    }

    // Load config
    configMap, err := readConfigFile(cfg.ConfigFile)
    if err != nil {
        return err
    }

    // Ensure auth map exists
    auth, _ := configMap["auth"].(map[string]interface{})
    if auth == nil {
        auth = make(map[string]interface{})
        configMap["auth"] = auth
    }

    // If RS256 already configured and not forcing, exit early
    if !cfg.JWTForce {
        if algo, ok := auth["jwt_algorithm"].(string); ok && algo == "RS256" {
            if priv, ok := auth["jwt_private_key_pem"].(string); ok && priv != "" {
                // Already configured
                fmt.Printf("RS256 JWT keys already present in %s; skipping.\n", cfg.ConfigFile)
                return nil
            }
        }
    }

    // Generate RSA private key
    bits := cfg.JWTKeyBits
    if bits < 2048 {
        bits = 2048
    }
    key, err := rsa.GenerateKey(rand.Reader, bits)
    if err != nil {
        return fmt.Errorf("generate RSA key: %w", err)
    }

    // Marshal to PKCS8 for broad compatibility
    der, err := x509.MarshalPKCS8PrivateKey(key)
    if err != nil {
        return fmt.Errorf("marshal private key: %w", err)
    }
    pemBlock := &pem.Block{Type: "PRIVATE KEY", Bytes: der}
    pemBytes := pem.EncodeToMemory(pemBlock)

    // Derive kid if not provided: sha256 of modulus, first 16 hex chars
    kid := cfg.JWTKeyID
    if kid == "" {
        sum := sha256.Sum256(key.PublicKey.N.Bytes())
        kid = fmt.Sprintf("key-%x", sum[:8])
    }

    // Update auth section
    auth["jwt_algorithm"] = "RS256"
    auth["jwt_private_key_pem"] = string(pemBytes)
    auth["jwt_key_id"] = kid

    // Persist
    if err := writeConfigFile(cfg.ConfigFile, configMap); err != nil {
        return err
    }

    fmt.Printf("Wrote RS256 JWT keys (kid=%s, %dbit) to %s\n", kid, bits, cfg.ConfigFile)

    return nil
}

