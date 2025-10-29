package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
)

const (
	keyLength   = 32
	nonceLength = 12
)

var (
	// ErrInvalidKeyLength indicates the provided key is not the required size.
	ErrInvalidKeyLength = errors.New("secrets: encryption key must be 32 bytes")
	// ErrCiphertextTooShort indicates the ciphertext payload is shorter than the nonce.
	ErrCiphertextTooShort = errors.New("secrets: ciphertext too short")
)

// Cipher wraps AES-GCM helpers for encrypting sensitive blobs before storage.
type Cipher struct {
	key []byte
}

// NewCipher constructs a Cipher from the provided key bytes.
func NewCipher(key []byte) (*Cipher, error) {
	if len(key) != keyLength {
		return nil, ErrInvalidKeyLength
	}

	buf := make([]byte, keyLength)
	copy(buf, key)

	return &Cipher{key: buf}, nil
}

// Encrypt serialises plaintext using AES-256-GCM and returns a base64 payload.
func (c *Cipher) Encrypt(plaintext []byte) (string, error) {
	block, err := aes.NewCipher(c.key)
	if err != nil {
		return "", fmt.Errorf("secrets: create cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("secrets: init gcm: %w", err)
	}

	nonce := make([]byte, nonceLength)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", fmt.Errorf("secrets: generate nonce: %w", err)
	}

	ciphertext := gcm.Seal(nonce, nonce, plaintext, nil)

	return base64.StdEncoding.EncodeToString(ciphertext), nil
}

// Decrypt reverses Encrypt and returns the original plaintext bytes.
func (c *Cipher) Decrypt(encoded string) ([]byte, error) {
	payload, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("secrets: decode ciphertext: %w", err)
	}

	if len(payload) < nonceLength {
		return nil, ErrCiphertextTooShort
	}

	nonce := payload[:nonceLength]
	ciphertext := payload[nonceLength:]

	block, err := aes.NewCipher(c.key)
	if err != nil {
		return nil, fmt.Errorf("secrets: create cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("secrets: init gcm: %w", err)
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("secrets: decrypt payload: %w", err)
	}

	return plaintext, nil
}
