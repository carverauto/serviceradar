package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSanitizeObservabilityTable(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name       string
		input      string
		defaultVal string
		wantSQL    string
		wantCanon  string
	}{
		{
			name:       "default-when-empty",
			input:      "",
			defaultVal: "logs",
			wantSQL:    `"logs"`,
			wantCanon:  "logs",
		},
		{
			name:       "schema-table",
			input:      "observability.logs",
			defaultVal: "logs",
			wantSQL:    `"observability"."logs"`,
			wantCanon:  "observability.logs",
		},
		{
			name:       "trimmed-parts",
			input:      "  custom . metrics  ",
			defaultVal: "otel_metrics",
			wantSQL:    `"custom"."metrics"`,
			wantCanon:  "custom.metrics",
		},
		{
			name:       "leading-dot",
			input:      ".traces",
			defaultVal: "otel_traces",
			wantSQL:    `"traces"`,
			wantCanon:  "traces",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			sql, canon := sanitizeObservabilityTable(tc.input, tc.defaultVal)
			require.Equal(t, tc.wantSQL, sql)
			require.Equal(t, tc.wantCanon, canon)
		})
	}
}
