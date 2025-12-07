package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNormalizeDeletionMetadataClearsDeletionFlagsOnUpsert(t *testing.T) {
	t.Parallel()

	meta := map[string]string{
		"_deleted": "false",
		"ip":       "10.0.0.1",
		"foo":      "bar",
	}

	cleaned := normalizeDeletionMetadata(meta)

	assert.NotContains(t, cleaned, "_deleted")
	assert.NotContains(t, cleaned, "deleted")
	assert.Equal(t, "10.0.0.1", cleaned["ip"])
	assert.Equal(t, "bar", cleaned["foo"])

	// Ensure original map is not mutated for callers.
	assert.Equal(t, "false", meta["_deleted"])
}

func TestNormalizeDeletionMetadataPreservesExplicitDeletion(t *testing.T) {
	t.Parallel()

	meta := map[string]string{
		"_deleted": "true",
		"ip":       "10.0.0.1",
	}

	cleaned := normalizeDeletionMetadata(meta)

	assert.Equal(t, "true", cleaned["_deleted"])
	assert.Equal(t, "10.0.0.1", cleaned["ip"])
}
