package natsutil

import (
	"errors"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

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
			subject:  "events.poller.health",
			want:     []string{"events.poller.health"},
		},
		{
			name:     "keeps list when wildcard matches",
			subjects: []string{"events.poller.*"},
			subject:  "events.poller.health",
			want:     []string{"events.poller.*"},
		},
		{
			name:     "keeps list when greater wildcard matches",
			subjects: []string{"events.>"},
			subject:  "events.poller.health",
			want:     []string{"events.>"},
		},
		{
			name:     "appends when unmatched",
			subjects: []string{"events.syslog.*"},
			subject:  "events.poller.health",
			want:     []string{"events.syslog.*", "events.poller.health"},
		},
	}

	for _, tc := range tests {
		tc := tc
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
		{"exact match", "events.poller.health", "events.poller.health", true},
		{"single wildcard", "events.*.health", "events.poller.health", true},
		{"greater wildcard", "events.>", "events.poller.health", true},
		{"no match length", "events.*", "events.poller.health", false},
		{"no match tokens", "events.syslog.*", "events.poller.health", false},
	}

	for _, tc := range tests {
		tc := tc
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
		{"other error", errors.New("boom"), false},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := isStreamMissingErr(tc.err); got != tc.expected {
				t.Fatalf("isStreamMissingErr(%v) = %t, want %t", tc.err, got, tc.expected)
			}
		})
	}
}
