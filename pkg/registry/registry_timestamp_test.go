package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestParseFirstSeenTimestampHandlesNewFormats(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name     string
		input    string
		expected time.Time
	}{
		{
			name:     "SpaceSeparatedWithZ",
			input:    "2025-02-12 12:34:56Z",
			expected: time.Date(2025, time.February, 12, 12, 34, 56, 0, time.UTC),
		},
		{
			name:     "SpaceSeparatedWithFractionAndZ",
			input:    "2025-02-12 12:34:56.123456Z",
			expected: time.Date(2025, time.February, 12, 12, 34, 56, 123456000, time.UTC),
		},
		{
			name:     "SpaceSeparatedWithOffsetMissingColon",
			input:    "2025-02-12 12:34:56.654321+0000",
			expected: time.Date(2025, time.February, 12, 12, 34, 56, 654321000, time.UTC),
		},
		{
			name:     "TSeparatedWithOffsetMissingColon",
			input:    "2025-02-12T12:34:56.000123-0700",
			expected: time.Date(2025, time.February, 12, 19, 34, 56, 123000, time.UTC),
		},
		{
			name:     "SpaceSeparatedUTCKeyword",
			input:    "2025-02-12 12:34:56 UTC",
			expected: time.Date(2025, time.February, 12, 12, 34, 56, 0, time.UTC),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got, ok := parseFirstSeenTimestamp(tc.input)
			require.True(t, ok, "expected parse to succeed for %q", tc.input)
			require.True(t, got.Equal(tc.expected), "expected %v, got %v", tc.expected, got)
		})
	}
}
