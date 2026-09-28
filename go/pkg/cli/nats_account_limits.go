/*
 * Copyright 2026 Carver Automation Corporation.
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

package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/nats-io/jwt/v2"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

const (
	defaultNATSCredsDir     = "/etc/serviceradar/creds"
	natsOperatorSeedEnv     = "NATS_OPERATOR_SEED"
	natsOperatorSeedFile    = "operator.seed"
	natsAccountJWTSubdir    = "jwt"
	natsAccountJWTFileMode  = 0o644
	natsAccountJWTExtension = ".jwt"
)

var errMultiplePlatformAccounts = errors.New("more than one account JWT matches")

// NatsAccountLimitsHandler handles flags for the nats-account-limits subcommand.
type NatsAccountLimitsHandler struct{}

// Parse processes the command-line arguments for the nats-account-limits subcommand.
func (NatsAccountLimitsHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("nats-account-limits", flag.ExitOnError)
	credsDir := fs.String("creds-dir", defaultNATSCredsDir, "Directory holding operator.seed and the jwt/ account JWTs written by nats-bootstrap")
	account := fs.String("account", defaultPlatformAccount, "Name of the account whose JetStream quota follows the sizing profile")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing nats-account-limits flags: %w", err)
	}

	cfg.NATSOutputDir = strings.TrimSpace(*credsDir)
	cfg.NATSPlatformAccount = strings.TrimSpace(*account)

	return nil
}

// RunNatsAccountLimits re-issues the platform account JWT with the JetStream
// quota of the loaded sizing profile (SERVICERADAR_NATS_MAX_FILE_STORE), so an
// install bootstrapped with the fixed default quota converges on the next
// start. It changes only the account's JetStream limits; the account key, and
// so every user credential, stays valid. It is a no-op when the profile
// variable is unset or the account already carries the quota.
func RunNatsAccountLimits(cfg *CmdConfig) error {
	sizing, err := accounts.JetStreamSizingFromEnv(os.LookupEnv)
	if err != nil {
		return err
	}

	credsDir := cfg.NATSOutputDir
	if credsDir == "" {
		credsDir = defaultNATSCredsDir
	}

	seed := strings.TrimSpace(os.Getenv(natsOperatorSeedEnv))
	if seed == "" {
		data, readErr := os.ReadFile(filepath.Join(credsDir, natsOperatorSeedFile))
		if readErr == nil {
			seed = strings.TrimSpace(string(data))
		}
	}

	_, err = resizeAccountJetStream(credsDir, cfg.NATSPlatformAccount, seed, sizing, os.Stdout)

	return err
}

// resizeAccountJetStream applies sizing to the named account's JWT under
// credsDir/jwt, signed with operatorSeed. It reports whether a file changed.
//
// A missing sizing, operator seed or account is reported on out and is not an
// error: refusing here would stop NATS from starting, while an account left on
// the default quota only stops new streams beyond it from being placed.
func resizeAccountJetStream(
	credsDir, accountName, operatorSeed string,
	sizing *accounts.JetStreamSizing,
	out io.Writer,
) (bool, error) {
	if sizing == nil {
		_, _ = fmt.Fprintf(out, "%s is not set; leaving NATS account JetStream limits unchanged\n", accounts.MaxFileStoreEnv)
		return false, nil
	}

	if operatorSeed == "" {
		_, _ = fmt.Fprintf(out, "WARNING: no operator seed (%s or %s); cannot re-issue account %q with a %d-byte JetStream quota\n",
			natsOperatorSeedEnv, filepath.Join(credsDir, natsOperatorSeedFile), accountName, sizing.DiskStorage)
		return false, nil
	}

	operator, err := accounts.NewOperator(&accounts.OperatorConfig{Name: defaultNATSOperatorName, OperatorSeed: operatorSeed})
	if err != nil {
		return false, fmt.Errorf("load operator: %w", err)
	}

	path, current, err := findAccountJWT(filepath.Join(credsDir, natsAccountJWTSubdir), accountName, operator.PublicKey(), out)
	if err != nil {
		return false, err
	}

	if path == "" {
		_, _ = fmt.Fprintf(out, "no account %q issued by this operator under %s; nothing to resize\n", accountName, credsDir)
		return false, nil
	}

	signer := accounts.NewAccountSigner(operator)

	resized, changed, err := signer.ResizeAccountJetStream(current, *sizing)
	if err != nil {
		return false, err
	}

	if !changed {
		_, _ = fmt.Fprintf(out, "account %q already has a %d-byte JetStream quota\n", accountName, sizing.DiskStorage)
		return false, nil
	}

	if err := writeFileAtomic(path, []byte(resized), natsAccountJWTFileMode); err != nil {
		return false, err
	}

	_, _ = fmt.Fprintf(out, "re-issued account %q (%s) with a %d-byte JetStream quota\n", accountName, filepath.Base(path), sizing.DiskStorage)

	return true, nil
}

// findAccountJWT returns the path and content of the one account JWT in dir
// named accountName and issued by operatorPublicKey, or "" when there is none.
func findAccountJWT(dir, accountName, operatorPublicKey string, out io.Writer) (string, string, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return "", "", nil
	}

	if err != nil {
		return "", "", fmt.Errorf("read %s: %w", dir, err)
	}

	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), natsAccountJWTExtension) {
			names = append(names, entry.Name())
		}
	}

	sort.Strings(names)

	var foundPath, foundJWT string

	for _, name := range names {
		path := filepath.Join(dir, name)

		data, err := os.ReadFile(path)
		if err != nil {
			return "", "", fmt.Errorf("read %s: %w", path, err)
		}

		token := strings.TrimSpace(string(data))

		claims, err := jwt.DecodeAccountClaims(token)
		if err != nil {
			_, _ = fmt.Fprintf(out, "skipping %s: not an account JWT: %v\n", path, err)
			continue
		}

		if claims.Name != accountName || claims.Issuer != operatorPublicKey {
			continue
		}

		if foundPath != "" {
			return "", "", fmt.Errorf("%w %q: %s and %s", errMultiplePlatformAccounts, accountName, foundPath, path)
		}

		foundPath, foundJWT = path, token
	}

	return foundPath, foundJWT, nil
}

// writeFileAtomic replaces path with data through a rename, so a reader never
// sees a partly written JWT.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp file for %s: %w", path, err)
	}

	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write %s: %w", tmpName, err)
	}

	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close %s: %w", tmpName, err)
	}

	if err := os.Chmod(tmpName, mode); err != nil {
		return fmt.Errorf("chmod %s: %w", tmpName, err)
	}

	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("replace %s: %w", path, err)
	}

	return nil
}
