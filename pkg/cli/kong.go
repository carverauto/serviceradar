package cli

import (
    "crypto/rsa"
    "crypto/x509"
    "encoding/base64"
    "encoding/json"
    "encoding/pem"
    "errors"
    "flag"
    "fmt"
    "io"
    "math/big"
    "net/http"
    "os"
    "strings"
)

// RenderKongHandler handles flags for the render-kong subcommand.
type RenderKongHandler struct{}

// Parse processes arguments for render-kong.
func (RenderKongHandler) Parse(args []string, cfg *CmdConfig) error {
    fs := flag.NewFlagSet("render-kong", flag.ExitOnError)
    jwks := fs.String("jwks", "http://core:8090/auth/jwks.json", "JWKS URL")
    service := fs.String("service", "http://core:8090", "Upstream service URL")
    path := fs.String("path", "/api", "Route path prefix")
    out := fs.String("out", "/etc/kong/kong.yml", "Output DB-less YAML path")
    keyClaim := fs.String("key-claim", "kid", "JWT key claim name to map keys")
    if err := fs.Parse(args); err != nil {
        return fmt.Errorf("parsing render-kong flags: %w", err)
    }
    cfg.JWKSURL = *jwks
    cfg.KongServiceURL = *service
    cfg.KongRoutePath = *path
    cfg.OutputPath = *out
    cfg.JWTKeyClaim = *keyClaim

    return nil
}

// RunRenderKong fetches JWKS and writes a DB-less kong.yml.
func RunRenderKong(cfg *CmdConfig) error {
    if cfg.OutputPath == "" {
        return errors.New("missing --out path")
    }
    pemKeys, err := fetchJWKSAsPEMs(cfg.JWKSURL)
    if err != nil {
        return fmt.Errorf("fetching JWKS: %w", err)
    }
    if len(pemKeys) == 0 {
        return errors.New("no RSA keys found in JWKS")
    }
    content := renderKongDBLess(cfg.KongServiceURL, cfg.KongRoutePath, cfg.JWTKeyClaim, pemKeys)
    if err := os.WriteFile(cfg.OutputPath, []byte(content), 0644); err != nil {
        return fmt.Errorf("writing %s: %w", cfg.OutputPath, err)
    }
    fmt.Printf("Wrote Kong DB-less config with %d key(s) to %s\n", len(pemKeys), cfg.OutputPath)

    return nil
}

type jwk struct {
    Kty string `json:"kty"`
    Kid string `json:"kid"`
    N   string `json:"n"`
    E   string `json:"e"`
}

type jwks struct {
    Keys []jwk `json:"keys"`
}

type pemKey struct {
    Kid string
    PEM string
}

func fetchJWKSAsPEMs(url string) ([]pemKey, error) {
    resp, err := http.Get(url) //nolint:gosec // URL provided by admin in trusted context
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
    }
    body, err := io.ReadAll(resp.Body)
    if err != nil {
        return nil, err
    }
    var set jwks
    if err := json.Unmarshal(body, &set); err != nil {
        return nil, err
    }
    var out []pemKey
    for _, k := range set.Keys {
        if strings.ToUpper(k.Kty) != "RSA" || k.N == "" || k.E == "" {
            continue
        }
        pemStr, err := rsaJWKToPEM(k.N, k.E)
        if err != nil {
            continue
        }
        out = append(out, pemKey{Kid: k.Kid, PEM: pemStr})
    }

    return out, nil
}

func b64ToBigInt(b64url string) (*big.Int, error) {
    if m := len(b64url) % 4; m != 0 {
        b64url += strings.Repeat("=", 4-m)
    }
    b, err := base64.URLEncoding.DecodeString(b64url)
    if err != nil {
        return nil, err
    }
    z := new(big.Int)
    z.SetBytes(b)

    return z, nil
}

func rsaJWKToPEM(nB64, eB64 string) (string, error) {
    n, err := b64ToBigInt(nB64)
    if err != nil {
        return "", err
    }
    e, err := b64ToBigInt(eB64)
    if err != nil {
        return "", err
    }
    if !e.IsInt64() {
        return "", errors.New("invalid exponent")
    }
    pub := &rsa.PublicKey{N: n, E: int(e.Int64())}
    der, err := x509.MarshalPKIXPublicKey(pub)
    if err != nil {
        return "", err
    }
    blk := &pem.Block{Type: "PUBLIC KEY", Bytes: der}

    return string(pem.EncodeToMemory(blk)), nil
}

func renderKongDBLess(serviceURL, routePath, keyClaim string, keys []pemKey) string {
    var b strings.Builder
    b.WriteString("_format_version: \"3.0\"\n")
    b.WriteString("_transform: true\n\n")
    b.WriteString("services:\n")
    b.WriteString("  - name: core-api\n")
    b.WriteString("    url: " + serviceURL + "\n")
    b.WriteString("    routes:\n")
    b.WriteString("      - name: core-api-routes\n")
    b.WriteString("        paths:\n")
    b.WriteString("          - " + routePath + "\n")
    b.WriteString("        strip_path: false\n\n")
    b.WriteString("consumers:\n")
    b.WriteString("  - username: jwks-consumer\n\n")
    b.WriteString("plugins:\n")
    b.WriteString("  - name: jwt\n")
    b.WriteString("    route: core-api-routes\n")
    b.WriteString("    enabled: true\n")
    b.WriteString("    config:\n")
    b.WriteString("      key_claim_name: " + keyClaim + "\n")
    b.WriteString("      claims_to_verify:\n")
    b.WriteString("        - exp\n")
    b.WriteString("      run_on_preflight: true\n\n")
    b.WriteString("jwt_secrets:\n")
    for _, k := range keys {
        b.WriteString("  - consumer: jwks-consumer\n")
        b.WriteString("    algorithm: RS256\n")
        b.WriteString("    key: " + k.Kid + "\n")
        b.WriteString("    rsa_public_key: |\n")
        for _, line := range strings.Split(strings.TrimSpace(k.PEM), "\n") {
            b.WriteString("      ")
            b.WriteString(line)
            b.WriteString("\n")
        }
    }

    return b.String()
}

