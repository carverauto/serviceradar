package registry

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestEscapeLiteral(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "plain string unchanged",
			input:    "poller-123",
			expected: "poller-123",
		},
		{
			name:     "single quote doubled",
			input:    "O'Reilly",
			expected: "O''Reilly",
		},
		{
			name:     "sql injection attempt neutralised",
			input:    "poller'); DROP TABLE pollers; --",
			expected: "poller''); DROP TABLE pollers; --",
		},
	}

	for _, tt := range tests {
		tc := tt
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			require.Equal(t, tc.expected, escapeLiteral(tc.input))
		})
	}
}

func TestQuoteStringSlice(t *testing.T) {
	t.Parallel()

	values := []string{
		"active",
		"", // should be skipped
		"revoked'); DROP TABLE pollers; --",
	}

	quoted := quoteStringSlice(values)

	require.NotEmpty(t, quoted)
	require.Contains(t, quoted, "'active'")
	require.Contains(t, quoted, "'revoked''); DROP TABLE pollers; --'")
	require.NotContains(t, quoted, "'revoked'); DROP TABLE pollers; --'")
	require.NotContains(t, quoted, ",''")
}

func TestGetPollerQueryEscapesUserInput(t *testing.T) {
	t.Parallel()

	malicious := "poller'); DROP TABLE pollers; --"
	query := fmt.Sprintf(`SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM table(pollers)
	WHERE poller_id = '%s'
	ORDER BY _tp_time DESC
	LIMIT 1`, escapeLiteral(malicious))

	require.Contains(t, query, "poller''); DROP TABLE pollers; --")
	require.NotContains(t, query, "poller'); DROP TABLE pollers; --")
}
