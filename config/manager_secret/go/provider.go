package secret

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// MountedSecretsDir is where a deployment mounts its secrets.
//
// A constant for the same reason the instance mount is one: the platform decides what to put
// there, and a settable path would be a second thing able to disagree with the environment.
// Kubernetes secrets, Docker secrets and a developer's directory are all files, so one provider
// serves every environment.
const MountedSecretsDir = "/etc/serviceradar/secrets"

// Provider resolves a logical name to a value.
//
// Logical names are identical across environments and languages; only the provider changes, and
// which provider is in use follows from SERVICERADAR_ENV.
type Provider interface {
	// Describe is a short name for diagnostics. An unresolvable secret must say WHICH store was
	// consulted, or the reader cannot tell where to put the missing value.
	Describe() string
	Resolve(name string) (Secret, error)
}

// FileProvider reads one file per logical name, which is how Kubernetes and Docker present
// secrets.
type FileProvider struct {
	dir   string
	label string
}

func NewFileProvider(dir, label string) FileProvider {
	return FileProvider{dir: dir, label: label}
}

func MountedProvider() FileProvider {
	return NewFileProvider(MountedSecretsDir, "file("+MountedSecretsDir+")")
}

func (p FileProvider) Describe() string { return p.label }

func (p FileProvider) Resolve(name string) (Secret, error) {
	raw, err := os.ReadFile(filepath.Join(p.dir, name))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Secret{}, &Error{Kind: Unresolvable, Name: name, Provider: p.label}
		}
		return Secret{}, &Error{
			Kind: ProviderFailed, Name: name, Provider: p.label, Detail: err.Error(),
		}
	}
	// A trailing newline is an artefact of how the file was written, not part of the secret.
	// Everything else is preserved: a password may legitimately contain spaces.
	value, ok := NewSecret(strings.TrimRight(string(raw), "\r\n"))
	if !ok {
		return Secret{}, &Error{Kind: Unresolvable, Name: name, Provider: p.label}
	}
	return value, nil
}
