/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/remoteaccess/sshca"
)

const (
	defaultCAKeyEnv          = "SERVICERADAR_SSH_CA_KEY"
	defaultCAPassphraseEnv   = "SERVICERADAR_SSH_CA_PASSPHRASE"
	defaultRequestFileEnv    = "SERVICERADAR_SSHCA_SIGN_REQUEST_FILE"
	defaultMaxCertificateTTL = 8 * time.Hour
)

var (
	errCAKeySourceRequired = errors.New("CA key source is required")
	errCAKeyRequired       = errors.New("CA key is required")
)

type signRequest struct {
	PublicKey       string            `json:"public_key"`
	KeyID           string            `json:"key_id"`
	Principals      []string          `json:"principals"`
	TTLSeconds      int64             `json:"ttl_seconds"`
	Serial          uint64            `json:"serial,omitempty"`
	ValidAfter      string            `json:"valid_after,omitempty"`
	CriticalOptions map[string]string `json:"critical_options,omitempty"`
	Extensions      map[string]string `json:"extensions,omitempty"`
}

type signResponse struct {
	Certificate string `json:"certificate"`
	ExpiresAt   string `json:"expires_at"`
	Fingerprint string `json:"fingerprint"`
	Serial      uint64 `json:"serial"`
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv))
}

func run(
	args []string,
	stdin io.Reader,
	stdout io.Writer,
	stderr io.Writer,
	getenv func(string) string,
) int {
	var (
		caKeyFile        string
		caKeyEnv         string
		caPassphraseEnv  string
		maxCertificateTT time.Duration
	)

	flags := flag.NewFlagSet("serviceradar-sshca-signer", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&caKeyFile, "ca-key-file", "", "path to the OpenSSH/PEM SSH CA private key")
	flags.StringVar(&caKeyEnv, "ca-key-env", defaultCAKeyEnv, "environment variable containing the SSH CA private key")
	flags.StringVar(&caPassphraseEnv, "ca-passphrase-env", defaultCAPassphraseEnv, "environment variable containing the SSH CA private key passphrase")
	flags.DurationVar(&maxCertificateTT, "max-ttl", defaultMaxCertificateTTL, "maximum certificate TTL")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	caKey, err := loadCAKey(caKeyFile, caKeyEnv, getenv)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: %v\n", err)
		return 2
	}

	requestReader, closeRequest, err := signerRequestReader(stdin, getenv(defaultRequestFileEnv))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: %v\n", err)
		return 2
	}
	defer closeRequest()

	req, err := decodeRequest(requestReader)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: %v\n", err)
		return 2
	}
	sshReq, err := req.toSSHCARequest()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: %v\n", err)
		return 2
	}

	ca, err := sshca.New(caKey, []byte(getenv(caPassphraseEnv)), sshca.WithMaxTTL(maxCertificateTT))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: initialize signer: %v\n", err)
		return 2
	}

	signed, err := ca.SignUserCertificate(sshReq)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: sign certificate: %v\n", err)
		return 1
	}

	resp := signResponse{
		Certificate: strings.TrimSpace(string(signed.AuthorizedKey)),
		ExpiresAt:   signed.ExpiresAt.UTC().Format(time.RFC3339),
		Fingerprint: signed.PublicKeyFingerprint,
		Serial:      signed.Certificate.Serial,
	}
	if err := json.NewEncoder(stdout).Encode(resp); err != nil {
		_, _ = fmt.Fprintf(stderr, "sshca-signer: encode response: %v\n", err)
		return 1
	}

	return 0
}

func loadCAKey(path, envName string, getenv func(string) string) ([]byte, error) {
	if strings.TrimSpace(path) != "" {
		key, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read CA key file: %w", err)
		}
		return key, nil
	}

	if strings.TrimSpace(envName) == "" {
		return nil, errCAKeySourceRequired
	}

	key := []byte(getenv(envName))
	if strings.TrimSpace(string(key)) == "" {
		return nil, fmt.Errorf("%w in %s or --ca-key-file", errCAKeyRequired, envName)
	}
	return key, nil
}

func signerRequestReader(stdin io.Reader, requestFile string) (io.Reader, func(), error) {
	requestFile = strings.TrimSpace(requestFile)
	if requestFile == "" {
		return stdin, func() {}, nil
	}

	file, err := os.Open(requestFile)
	if err != nil {
		return nil, func() {}, fmt.Errorf("read request file: %w", err)
	}

	return file, func() { _ = file.Close() }, nil
}

func decodeRequest(stdin io.Reader) (signRequest, error) {
	var req signRequest
	decoder := json.NewDecoder(stdin)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		return signRequest{}, fmt.Errorf("decode request: %w", err)
	}
	return req, nil
}

func (req signRequest) toSSHCARequest() (sshca.UserCertificateRequest, error) {
	validAfter, err := parseTime(req.ValidAfter)
	if err != nil {
		return sshca.UserCertificateRequest{}, err
	}

	return sshca.UserCertificateRequest{
		PublicKey:       []byte(req.PublicKey),
		KeyID:           req.KeyID,
		Principals:      req.Principals,
		TTL:             time.Duration(req.TTLSeconds) * time.Second,
		ValidAfter:      validAfter,
		Serial:          req.Serial,
		CriticalOptions: req.CriticalOptions,
		Extensions:      req.Extensions,
	}, nil
}

func parseTime(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}

	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("valid_after must be RFC3339: %w", err)
	}

	return parsed, nil
}
