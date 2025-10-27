package datasvc

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestConfigValidateRejectsBucketHistoryTooLarge(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		BucketHistory: math.MaxUint8 + 1,
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
		NATSSecurity: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errBucketHistoryTooLarge)
}

func TestConfigValidateAllowsSPIFFE(t *testing.T) {
	cfg := &Config{
		ListenAddr: "127.0.0.1:0",
		NATSURL:    "nats://127.0.0.1:4222",
		Security: &models.SecurityConfig{
			Mode:           models.SecurityMode("spiffe"),
			TrustDomain:    "example.org",
			WorkloadSocket: "unix:/run/spire/sockets/agent.sock",
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
		NATSSecurity: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	require.NoError(t, cfg.Validate())
}

func TestConfigValidateRejectsUnknownSecurityMode(t *testing.T) {
	cfg := &Config{
		ListenAddr: "127.0.0.1:0",
		NATSURL:    "nats://127.0.0.1:4222",
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("bogus"),
		},
		NATSSecurity: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errInvalidSecurityMode)
}

func TestConfigValidateRequiresNATSSecurity(t *testing.T) {
	cfg := &Config{
		ListenAddr: "127.0.0.1:0",
		NATSURL:    "nats://127.0.0.1:4222",
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errNATSSecurityRequired)
}

func TestConfigValidateRejectsNonMTLSNATSSecurity(t *testing.T) {
	cfg := &Config{
		ListenAddr: "127.0.0.1:0",
		NATSURL:    "nats://127.0.0.1:4222",
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
		NATSSecurity: &models.SecurityConfig{
			Mode: models.SecurityMode("spiffe"),
		},
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errMTLSRequired)
}

func TestConfigValidateRequiresNATSTLSFiles(t *testing.T) {
	cfg := &Config{
		ListenAddr: "127.0.0.1:0",
		NATSURL:    "nats://127.0.0.1:4222",
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
		NATSSecurity: &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "",
				CAFile:   "ca.pem",
			},
		},
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errKeyFileRequired)
}
