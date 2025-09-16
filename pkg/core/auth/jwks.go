package auth

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"

	"github.com/carverauto/serviceradar/pkg/models"
)

// JWK represents a single RSA public key in JWK format
type JWK struct {
	Kty string `json:"kty"`           // Key Type, e.g., "RSA"
	Kid string `json:"kid,omitempty"` // Key ID
	Use string `json:"use,omitempty"` // Public key use, e.g., "sig"
	Alg string `json:"alg,omitempty"` // Algorithm, e.g., "RS256"
	N   string `json:"n,omitempty"`   // Modulus, base64url
	E   string `json:"e,omitempty"`   // Exponent, base64url
}

// JWKSet is a set of JWK keys
type JWKSet struct {
	Keys []JWK `json:"keys"`
}

// PublicJWKSJSON builds a JWKS JSON document from the configured RSA keys.
// Currently derives the public key from JWTPrivateKeyPEM if RS256 is enabled.
func PublicJWKSJSON(cfg *models.AuthConfig) ([]byte, error) {
	if cfg == nil || cfg.JWTAlgorithm != algorithmRS256 {
		// Empty set if RS256 not enabled
		return json.Marshal(JWKSet{Keys: []JWK{}})
	}

	// Prefer public key PEM if provided, otherwise derive from private key
	var pub *rsa.PublicKey
	var err error
	if cfg.JWTPublicKeyPEM != "" {
		pub, err = parseRSAPublicKey(cfg.JWTPublicKeyPEM)
		if err != nil {
			return nil, err
		}
	} else {
		priv, _, err := parseRSAPrivateKey(cfg.JWTPrivateKeyPEM, cfg.JWTKeyID)
		if err != nil {
			return nil, err
		}
		pub = &priv.PublicKey
	}

	jwk := rsaPublicKeyToJWK(pub, cfg.JWTKeyID)
	jwk.Use = "sig"
	jwk.Alg = algorithmRS256
	return json.Marshal(JWKSet{Keys: []JWK{jwk}})
}

func rsaPublicKeyToJWK(pub *rsa.PublicKey, kid string) JWK {
	return JWK{
		Kty: "RSA",
		Kid: kid,
		N:   base64urlBigInt(pub.N),
		E:   base64urlBigInt(big.NewInt(int64(pub.E))),
	}
}

func base64urlBigInt(n *big.Int) string {
	// big-endian bytes
	b := n.Bytes()
	// base64 URL without padding
	return base64.RawURLEncoding.EncodeToString(b)
}
