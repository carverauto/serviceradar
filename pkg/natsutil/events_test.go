package natsutil

import (
	"context"
	"errors"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/pkg/tenant"
)

var errTestFixture = errors.New("fixture error")

func TestEnsureSubjectList(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		subjects []string
		subject  string
		want     []string
	}{
		{
			name:     "adds subject when list empty",
			subjects: nil,
			subject:  "events.ocsf.processed",
			want:     []string{"events.ocsf.processed"},
		},
		{
			name:     "keeps list when wildcard matches",
			subjects: []string{"events.ocsf.*"},
			subject:  "events.ocsf.processed",
			want:     []string{"events.ocsf.*"},
		},
		{
			name:     "keeps list when greater wildcard matches",
			subjects: []string{"events.>"},
			subject:  "events.ocsf.processed",
			want:     []string{"events.>"},
		},
		{
			name:     "appends when unmatched",
			subjects: []string{"logs.syslog.*"},
			subject:  "events.ocsf.processed",
			want:     []string{"logs.syslog.*", "events.ocsf.processed"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			result := ensureSubjectList(append([]string(nil), tc.subjects...), tc.subject)

			if len(result) != len(tc.want) {
				t.Fatalf("expected %d subjects, got %d", len(tc.want), len(result))
			}

			for i := range tc.want {
				if tc.want[i] != result[i] {
					t.Fatalf("result[%d] = %q, want %q", i, result[i], tc.want[i])
				}
			}
		})
	}
}

func TestMatchesSubject(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		pattern  string
		subject  string
		expected bool
	}{
		{"exact match", "events.ocsf.processed", "events.ocsf.processed", true},
		{"single wildcard", "events.*.processed", "events.ocsf.processed", true},
		{"greater wildcard", "events.>", "events.ocsf.processed", true},
		{"no match length", "events.*", "events.ocsf.processed", false},
		{"no match tokens", "logs.syslog.*", "events.ocsf.processed", false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := matchesSubject(tc.pattern, tc.subject); got != tc.expected {
				t.Fatalf("matchesSubject(%q, %q) = %t, want %t", tc.pattern, tc.subject, got, tc.expected)
			}
		})
	}
}

func TestIsStreamMissingErr(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		err      error
		expected bool
	}{
		{"jetstream no stream response", jetstream.ErrNoStreamResponse, true},
		{"jetstream stream not found", jetstream.ErrStreamNotFound, true},
		{"nats no stream response", nats.ErrNoStreamResponse, true},
		{"nats stream not found", nats.ErrStreamNotFound, true},
		{"nats no responders", nats.ErrNoResponders, true},
		{"other error", errTestFixture, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := isStreamMissingErr(tc.err); got != tc.expected {
				t.Fatalf("isStreamMissingErr(%v) = %t, want %t", tc.err, got, tc.expected)
			}
		})
	}
}

func TestIsTenantPrefixEnabled(t *testing.T) {
	tests := []struct {
		name     string
		envValue string
		expected bool
	}{
		{"true", "true", true},
		{"1", "1", true},
		{"yes", "yes", true},
		{"false", "false", false},
		{"empty", "", false},
		{"random", "random", false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Set environment variable for this test
			if tc.envValue != "" {
				t.Setenv(EnvNATSTenantPrefixEnabled, tc.envValue)
			} else {
				t.Setenv(EnvNATSTenantPrefixEnabled, "")
			}

			if got := IsTenantPrefixEnabled(); got != tc.expected {
				t.Fatalf("IsTenantPrefixEnabled() = %t, want %t (env=%q)", got, tc.expected, tc.envValue)
			}
		})
	}
}

func TestApplyTenantPrefix(t *testing.T) {
	tests := []struct {
		name             string
		prefixingEnabled bool
		tenantSlug       string
		subject          string
		expected         string
	}{
		{
			name:             "prefixing enabled with tenant in context",
			prefixingEnabled: true,
			tenantSlug:       "acme-corp",
			subject:          "events.ocsf.processed",
			expected:         "acme-corp.events.ocsf.processed",
		},
		{
			name:             "prefixing enabled without tenant defaults to 'default'",
			prefixingEnabled: true,
			tenantSlug:       "",
			subject:          "events.ocsf.processed",
			expected:         "default.events.ocsf.processed",
		},
		{
			name:             "prefixing disabled returns original subject",
			prefixingEnabled: false,
			tenantSlug:       "acme-corp",
			subject:          "events.ocsf.processed",
			expected:         "events.ocsf.processed",
		},
		{
			name:             "prefixing disabled without tenant returns original",
			prefixingEnabled: false,
			tenantSlug:       "",
			subject:          "events.ocsf.processed",
			expected:         "events.ocsf.processed",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			publisher := &EventPublisher{
				tenantPrefixing: tc.prefixingEnabled,
			}

			ctx := context.Background()
			if tc.tenantSlug != "" {
				ctx = tenant.WithContext(ctx, &tenant.Info{TenantSlug: tc.tenantSlug})
			}

			got := publisher.applyTenantPrefix(ctx, tc.subject)
			if got != tc.expected {
				t.Fatalf("applyTenantPrefix() = %q, want %q", got, tc.expected)
			}
		})
	}
}

func TestNewEventPublisherWithPrefixing(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name            string
		enablePrefixing bool
	}{
		{"prefixing enabled", true},
		{"prefixing disabled", false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			publisher := NewEventPublisherWithPrefixing(nil, "test-stream", []string{"events.>"}, tc.enablePrefixing)

			if publisher.IsTenantPrefixingEnabled() != tc.enablePrefixing {
				t.Fatalf("IsTenantPrefixingEnabled() = %t, want %t",
					publisher.IsTenantPrefixingEnabled(), tc.enablePrefixing)
			}
		})
	}
}

func TestSetTenantPrefixing(t *testing.T) {
	t.Parallel()

	publisher := &EventPublisher{tenantPrefixing: false}

	if publisher.IsTenantPrefixingEnabled() {
		t.Fatal("expected prefixing to be disabled initially")
	}

	publisher.SetTenantPrefixing(true)
	if !publisher.IsTenantPrefixingEnabled() {
		t.Fatal("expected prefixing to be enabled after SetTenantPrefixing(true)")
	}

	publisher.SetTenantPrefixing(false)
	if publisher.IsTenantPrefixingEnabled() {
		t.Fatal("expected prefixing to be disabled after SetTenantPrefixing(false)")
	}
}
