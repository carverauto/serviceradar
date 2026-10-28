package datasvc

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestConfigValidateRejectsBucketHistoryTooLarge(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
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

func TestConfigValidateRejectsSPIFFE(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
		Security: &models.SecurityConfig{
			Mode: models.SecurityMode("spiffe"),
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

	for _, mode := range []models.SecurityMode{"spiffe", "spire", "workload_api"} {
		cfg.Security.Mode = mode
		err := cfg.Validate()
		require.Error(t, err)
		require.ErrorIs(t, err, errInvalidSecurityMode)
		require.ErrorContains(t, err, "https://docs.serviceradar.cloud/docs/migrating-off-spire")
	}
}

func TestConfigValidateRejectsUnknownSecurityMode(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
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

func TestConfigValidateAllowsJWTOnlyNATSSecurity(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
		Security: &models.SecurityConfig{
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

func TestConfigValidateRequiresNATSSecurityWhenNoCredsProvided(t *testing.T) {
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
	require.ErrorIs(t, err, errNATSCredsRequired)
}

func TestConfigValidateRejectsNonMTLSNATSSecurity(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
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

	for _, mode := range []models.SecurityMode{"spiffe", "spire", "workload_api"} {
		cfg.NATSSecurity.Mode = mode
		err := cfg.Validate()
		require.Error(t, err)
		require.ErrorIs(t, err, errMTLSRequired)
		require.ErrorContains(t, err, "https://docs.serviceradar.cloud/docs/migrating-off-spire")
	}
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

func TestConfigValidateSetsDefaultObjectLimits(t *testing.T) {
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
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

	require.NoError(t, cfg.Validate())
	require.EqualValues(t, defaultObjectMaxBytes, cfg.ObjectMaxBytes)
	require.EqualValues(t, defaultObjectStoreBytes, cfg.ObjectStoreBytes)
	require.Equal(t, 1, cfg.JetStreamReplicas)
}

func TestConfigValidateRejectsNegativeObjectLimits(t *testing.T) {
	cfg := &Config{
		ListenAddr:       "127.0.0.1:0",
		NATSURL:          "nats://127.0.0.1:4222",
		NATSCredsFile:    "/etc/serviceradar/creds/platform.creds",
		ObjectMaxBytes:   -1,
		ObjectStoreBytes: -1,
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
	require.ErrorIs(t, err, errObjectMaxBytesNegative)

	cfg.ObjectMaxBytes = 1

	err = cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errObjectStoreBytesNegative)
}

func TestConfigValidateRejectsInvalidJetStreamReplicas(t *testing.T) {
	cfg := &Config{
		ListenAddr:        "127.0.0.1:0",
		NATSURL:           "nats://127.0.0.1:4222",
		NATSCredsFile:     "/etc/serviceradar/creds/platform.creds",
		JetStreamReplicas: 6,
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
	require.ErrorIs(t, err, errJetStreamReplicasInvalid)
}
