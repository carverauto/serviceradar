package bootstrap

import (
	"context"
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestCoreSecurityProviderFromEnvRejectsInsecureModes(t *testing.T) {
	testCases := []struct {
		name    string
		mode    string
		wantErr error
	}{
		{
			name:    "empty mode",
			mode:    "",
			wantErr: errCoreSecurityRequired,
		},
		{
			name:    "none mode",
			mode:    "none",
			wantErr: errInsecureCoreSecMode,
		},
		{
			name:    "unsupported mode",
			mode:    "bogus",
			wantErr: errUnsupportedCoreSecMode,
		},
	}

	for _, tc := range testCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CORE_SEC_MODE", tc.mode)

			provider, err := CoreSecurityProviderFromEnv(context.Background(), models.RoleAgent, logger.NewTestLogger())
			if provider != nil {
				t.Fatalf("expected nil provider, got %T", provider)
			}
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("expected error %v, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestCoreSecurityProviderFromEnvRejectsIncompleteMTLS(t *testing.T) {
	t.Setenv("CORE_SEC_MODE", "mtls")
	t.Setenv("CORE_CERT_FILE", "")
	t.Setenv("CORE_KEY_FILE", "")
	t.Setenv("CORE_CA_FILE", "")

	provider, err := CoreSecurityProviderFromEnv(context.Background(), models.RoleAgent, logger.NewTestLogger())
	if provider != nil {
		t.Fatalf("expected nil provider, got %T", provider)
	}
	if !errors.Is(err, errCoreMTLSConfig) {
		t.Fatalf("expected error %v, got %v", errCoreMTLSConfig, err)
	}
}

func TestBuildCoreDialOptionsFromEnvRejectsInsecureModes(t *testing.T) {
	testCases := []struct {
		name    string
		mode    string
		wantErr error
	}{
		{
			name:    "empty mode",
			mode:    "",
			wantErr: errCoreSecurityRequired,
		},
		{
			name:    "none mode",
			mode:    "none",
			wantErr: errInsecureCoreSecMode,
		},
	}

	for _, tc := range testCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CORE_SEC_MODE", tc.mode)

			dialOpts, closer, err := BuildCoreDialOptionsFromEnv(context.Background(), models.RoleAgent, logger.NewTestLogger())
			if len(dialOpts) != 0 {
				t.Fatalf("expected no dial options, got %d", len(dialOpts))
			}
			if closer == nil {
				t.Fatal("expected non-nil closer")
			}
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("expected error %v, got %v", tc.wantErr, err)
			}

			closer()
		})
	}
}
