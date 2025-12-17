package db

import (
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildCNPGConnURL_DefaultsSSLModeDisableWithoutTLS(t *testing.T) {
	t.Parallel()

	u, err := buildCNPGConnURL(&models.CNPGDatabase{
		Host:     "cnpg-rw",
		Port:     5432,
		Database: "serviceradar",
	})
	if err != nil {
		t.Fatalf("buildCNPGConnURL error: %v", err)
	}

	if got := u.Query().Get("sslmode"); got != "disable" {
		t.Fatalf("sslmode=%q, want %q", got, "disable")
	}
}

func TestBuildCNPGConnURL_DefaultsSSLModeVerifyFullWithTLS(t *testing.T) {
	t.Parallel()

	u, err := buildCNPGConnURL(&models.CNPGDatabase{
		Host:     "cnpg-rw",
		Port:     5432,
		Database: "serviceradar",
		TLS: &models.TLSConfig{
			CertFile: "client.crt",
			KeyFile:  "client.key",
			CAFile:   "ca.crt",
		},
	})
	if err != nil {
		t.Fatalf("buildCNPGConnURL error: %v", err)
	}

	if got := u.Query().Get("sslmode"); got != "verify-full" {
		t.Fatalf("sslmode=%q, want %q", got, "verify-full")
	}
}

func TestBuildCNPGConnURL_RejectsTLSWithSSLModeDisable(t *testing.T) {
	t.Parallel()

	_, err := buildCNPGConnURL(&models.CNPGDatabase{
		Host:     "cnpg-rw",
		Port:     5432,
		Database: "serviceradar",
		SSLMode:  "disable",
		TLS: &models.TLSConfig{
			CertFile: "client.crt",
			KeyFile:  "client.key",
			CAFile:   "ca.crt",
		},
	})
	if !errors.Is(err, ErrCNPGTLSDisabled) {
		t.Fatalf("error=%v, want %v", err, ErrCNPGTLSDisabled)
	}
}

func TestBuildCNPGConnURL_TLSPathsResolveViaCertDir(t *testing.T) {
	t.Parallel()

	u, err := buildCNPGConnURL(&models.CNPGDatabase{
		Host:     "cnpg-rw",
		Port:     5432,
		Database: "serviceradar",
		CertDir:  "/etc/serviceradar/cnpg",
		TLS: &models.TLSConfig{
			CertFile: "client.crt",
			KeyFile:  "client.key",
			CAFile:   "ca.crt",
		},
	})
	if err != nil {
		t.Fatalf("buildCNPGConnURL error: %v", err)
	}

	q := u.Query()
	if got := q.Get("sslcert"); got != "/etc/serviceradar/cnpg/client.crt" {
		t.Fatalf("sslcert=%q, want %q", got, "/etc/serviceradar/cnpg/client.crt")
	}
	if got := q.Get("sslkey"); got != "/etc/serviceradar/cnpg/client.key" {
		t.Fatalf("sslkey=%q, want %q", got, "/etc/serviceradar/cnpg/client.key")
	}
	if got := q.Get("sslrootcert"); got != "/etc/serviceradar/cnpg/ca.crt" {
		t.Fatalf("sslrootcert=%q, want %q", got, "/etc/serviceradar/cnpg/ca.crt")
	}
}

func TestResolveCNPGSSLMode_UsesRuntimeParamsFallback(t *testing.T) {
	t.Parallel()

	got, err := resolveCNPGSSLMode(&models.CNPGDatabase{
		ExtraRuntimeParams: map[string]string{
			"sslmode": "Verify-CA",
		},
	})
	if err != nil {
		t.Fatalf("resolveCNPGSSLMode error: %v", err)
	}
	if got != "verify-ca" {
		t.Fatalf("sslmode=%q, want %q", got, "verify-ca")
	}
}
