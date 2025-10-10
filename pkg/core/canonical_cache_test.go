package core

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestCanonicalCacheBatch(t *testing.T) {
	cache := newCanonicalCache(time.Minute)
	fixed := time.Unix(100, 0)
	cache.setNowFn(func() time.Time { return fixed })

	meta := map[string]string{"armis_device_id": "123"}
	cache.store("10.0.0.1", canonicalSnapshot{
		DeviceID: "default:10.0.0.1",
		MAC:      "aa:bb:cc:dd:ee:ff",
		Metadata: meta,
	})

	hits, misses := cache.getBatch([]string{"10.0.0.1", "10.0.0.2", "10.0.0.1"})
	require.Len(t, misses, 1)
	require.Contains(t, misses, "10.0.0.2")

	require.Len(t, hits, 1)
	snap := hits["10.0.0.1"]
	require.Equal(t, "default:10.0.0.1", snap.DeviceID)
	require.Equal(t, "AA:BB:CC:DD:EE:FF", snap.MAC)
	require.Equal(t, "123", snap.Metadata["armis_device_id"])

	// Verify snapshot is a clone
	snap.Metadata["armis_device_id"] = "mutated"
	hits, _ = cache.getBatch([]string{"10.0.0.1"})
	require.Equal(t, "123", hits["10.0.0.1"].Metadata["armis_device_id"])
}

func TestCanonicalCacheExpiry(t *testing.T) {
	cache := newCanonicalCache(500 * time.Millisecond)
	start := time.Unix(200, 0)
	cache.setNowFn(func() time.Time { return start })

	cache.store("10.0.0.5", canonicalSnapshot{DeviceID: "id"})

	hits, misses := cache.getBatch([]string{"10.0.0.5"})
	require.Len(t, hits, 1)
	require.Len(t, misses, 0)

	cache.setNowFn(func() time.Time { return start.Add(time.Second) })
	hits, misses = cache.getBatch([]string{"10.0.0.5"})
	require.Len(t, hits, 0)
	require.Len(t, misses, 1)
	require.Contains(t, misses, "10.0.0.5")
}
