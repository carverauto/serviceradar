package core

import (
	"strings"
	"sync"
	"time"
)

type canonicalSnapshot struct {
	DeviceID string
	MAC      string
	Metadata map[string]string
}

type canonicalCache struct {
	mu    sync.RWMutex
	ttl   time.Duration
	byIP  map[string]cacheEntry
	nowFn func() time.Time
}

type cacheEntry struct {
	snapshot  canonicalSnapshot
	expiresAt time.Time
}

func newCanonicalCache(ttl time.Duration) *canonicalCache {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &canonicalCache{
		ttl:   ttl,
		byIP:  make(map[string]cacheEntry),
		nowFn: time.Now,
	}
}

func (c *canonicalCache) setNowFn(now func() time.Time) {
	if now == nil {
		return
	}
	c.mu.Lock()
	c.nowFn = now
	c.mu.Unlock()
}

func (c *canonicalCache) getBatch(ips []string) (map[string]canonicalSnapshot, []string) {
	hits := make(map[string]canonicalSnapshot, len(ips))
	misses := make([]string, 0, len(ips))

	c.mu.RLock()
	defer c.mu.RUnlock()

	now := c.nowFn()
	seen := make(map[string]struct{}, len(ips))

	for _, rawIP := range ips {
		ip := strings.TrimSpace(rawIP)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}

		entry, ok := c.byIP[ip]
		if !ok || entry.expiresAt.Before(now) {
			misses = append(misses, ip)
			continue
		}
		hits[ip] = cloneSnapshot(entry.snapshot)
	}

	return hits, misses
}

func (c *canonicalCache) store(ip string, snapshot canonicalSnapshot) {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return
	}
	snapshot.DeviceID = strings.TrimSpace(snapshot.DeviceID)
	snapshot.MAC = strings.ToUpper(strings.TrimSpace(snapshot.MAC))

	c.mu.Lock()
	defer c.mu.Unlock()

	expiry := c.nowFn().Add(c.ttl)
	c.byIP[ip] = cacheEntry{
		snapshot:  cloneSnapshot(snapshot),
		expiresAt: expiry,
	}
}

func cloneSnapshot(src canonicalSnapshot) canonicalSnapshot {
	dst := canonicalSnapshot{
		DeviceID: src.DeviceID,
		MAC:      src.MAC,
	}
	if len(src.Metadata) > 0 {
		dst.Metadata = make(map[string]string, len(src.Metadata))
		for k, v := range src.Metadata {
			dst.Metadata[k] = v
		}
	}
	return dst
}
