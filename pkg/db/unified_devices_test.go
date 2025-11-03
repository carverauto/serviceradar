package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestJoinValueTuplesEscapesMaliciousInput(t *testing.T) {
	t.Parallel()

	values := []string{
		"default:10.0.0.1",
		"default:10.0.0.2'); DROP TABLE unified_devices; --",
	}

	result := joinValueTuples(values)

	require.Contains(t, result, "('default:10.0.0.1')")
	require.Contains(t, result, "('default:10.0.0.2''); DROP TABLE unified_devices; --')")
	require.NotContains(t, result, "('default:10.0.0.2'); DROP TABLE unified_devices; --')")
	require.NotContains(t, result, ",('')")
}

func TestDedupeStringsSkipsEmptyAndDuplicates(t *testing.T) {
	t.Parallel()

	values := []string{"", "default:10.0.0.1", "default:10.0.0.1", "default:10.0.0.2"}
	result := dedupeStrings(values)

	require.Equal(t, []string{"default:10.0.0.1", "default:10.0.0.2"}, result)
}

func TestJoinValueTuplesSkipsEmptyValues(t *testing.T) {
	t.Parallel()

	require.Empty(t, joinValueTuples([]string{""}))
	require.Empty(t, joinValueTuples([]string{"   ", ""}))
	require.Equal(t, "('a')", joinValueTuples([]string{"", "a", ""}))
}
