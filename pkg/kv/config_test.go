package kv

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
	}

	err := cfg.Validate()
	require.Error(t, err)
	require.ErrorIs(t, err, errBucketHistoryTooLarge)
}
