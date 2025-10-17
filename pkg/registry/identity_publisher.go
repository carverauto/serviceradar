package registry

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cenkalti/backoff/v5"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

type kvIdentityClient interface {
	Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	PutIfAbsent(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	Update(ctx context.Context, in *proto.UpdateRequest, opts ...grpc.CallOption) (*proto.UpdateResponse, error)
	Delete(ctx context.Context, in *proto.DeleteRequest, opts ...grpc.CallOption) (*proto.DeleteResponse, error)
}

type identityPublisher struct {
	kvClient   kvIdentityClient
	namespace  string
	ttlSeconds int64
	metrics    *identityPublisherMetrics
	logger     logger.Logger
	cache      *identityCache
}

const (
	identityInitialBackoff = 50 * time.Millisecond
	identityMaxBackoff     = 750 * time.Millisecond
	identityMaxElapsed     = 5 * time.Second
	identityCacheTTL       = 5 * time.Minute
)

// WithIdentityPublisher wires a KV-backed identity map publisher into the device registry.
func WithIdentityPublisher(client kvIdentityClient, namespace string, ttl time.Duration) Option {
	return func(r *DeviceRegistry) {
		if r == nil {
			return
		}
		r.identityPublisher = newIdentityPublisher(client, namespace, ttl, r.logger)
	}
}

type identityPublisherMetrics struct {
	publishBatches atomic.Int64
	publishedKeys  atomic.Int64
	deletedKeys    atomic.Int64
	failures       atomic.Int64
}

func newIdentityPublisherMetrics() *identityPublisherMetrics {
	return &identityPublisherMetrics{}
}

func (m *identityPublisherMetrics) recordPublish(keyCount int) {
	m.publishBatches.Add(1)
	m.publishedKeys.Add(int64(keyCount))
}

func (m *identityPublisherMetrics) recordDelete(keyCount int) {
	if keyCount <= 0 {
		return
	}
	m.deletedKeys.Add(int64(keyCount))
}

func (m *identityPublisherMetrics) recordFailure() {
	m.failures.Add(1)
}

type identityCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[string]identityCacheEntry
}

type identityCacheEntry struct {
	metadataHash   string
	attributesHash string
	revision       uint64
	expiresAt      time.Time
}

func newIdentityCache(ttl time.Duration) *identityCache {
	if ttl < 0 {
		ttl = 0
	}
	return &identityCache{
		ttl:     ttl,
		entries: make(map[string]identityCacheEntry),
	}
}

func (c *identityCache) get(key string) *identityCacheEntry {
	if c == nil {
		return nil
	}

	c.mu.RLock()
	entry, ok := c.entries[key]
	c.mu.RUnlock()
	if !ok {
		return nil
	}

	if !entry.expiresAt.IsZero() && time.Now().After(entry.expiresAt) {
		c.mu.Lock()
		if current, ok := c.entries[key]; ok && current.expiresAt.Equal(entry.expiresAt) {
			delete(c.entries, key)
		}
		c.mu.Unlock()
		return nil
	}

	e := entry
	return &e
}

func (c *identityCache) set(key, metadataHash, attrsHash string, revision uint64) {
	if c == nil {
		return
	}

	var expiresAt time.Time
	if c.ttl > 0 {
		expiresAt = time.Now().Add(c.ttl)
	}

	c.mu.Lock()
	c.entries[key] = identityCacheEntry{
		metadataHash:   metadataHash,
		attributesHash: attrsHash,
		revision:       revision,
		expiresAt:      expiresAt,
	}
	c.mu.Unlock()
}

func (c *identityCache) delete(key string) {
	if c == nil {
		return
	}

	c.mu.Lock()
	delete(c.entries, key)
	c.mu.Unlock()
}

func newIdentityPublisher(client kvIdentityClient, namespace string, ttl time.Duration, log logger.Logger) *identityPublisher {
	if client == nil {
		return nil
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = identitymap.DefaultNamespace
	}
	return &identityPublisher{
		kvClient:   client,
		namespace:  ns,
		ttlSeconds: int64(ttl / time.Second),
		metrics:    newIdentityPublisherMetrics(),
		logger:     log,
		cache:      newIdentityCache(identityCacheTTL),
	}
}

func (p *identityPublisher) Publish(ctx context.Context, updates []*models.DeviceUpdate) error {
	if p == nil || p.kvClient == nil || len(updates) == 0 {
		return nil
	}

	now := time.Now().UTC()
	var publishErr error

	for _, update := range updates {
		if update == nil || shouldSkipIdentityPublish(update) {
			continue
		}

		record := &identitymap.Record{
			CanonicalDeviceID: update.DeviceID,
			Partition:         update.Partition,
			MetadataHash:      identitymap.HashIdentityMetadata(update),
			UpdatedAt:         now,
			Attributes:        buildIdentityAttributes(update),
		}

		payload, err := identitymap.MarshalRecord(record)
		if err != nil {
			publishErr = errors.Join(publishErr, fmt.Errorf("marshal canonical record: %w", err))
			continue
		}

		snapshot, snapErr := p.existingIdentitySnapshot(ctx, update.DeviceID)
		if snapErr != nil {
			publishErr = errors.Join(publishErr, snapErr)
		}
		if snapshot != nil && snapshot.canonicalKey != "" {
			p.cache.set(snapshot.canonicalKey, snapshot.metadataHash, snapshot.attrsHash, snapshot.revision)
		}

		newKeySet := make(map[string]struct{})

		for _, key := range identitymap.BuildKeys(update) {
			keyPath := key.KeyPath(p.namespace)
			newKeySet[keyPath] = struct{}{}
			if err := p.upsertIdentity(ctx, keyPath, payload, record.MetadataHash, record.Attributes); err != nil {
				publishErr = errors.Join(publishErr, err)
			}
		}

		if snapshot != nil {
			if stale := snapshot.staleKeys(newKeySet); len(stale) > 0 {
				if err := p.deleteIdentityKeys(ctx, stale); err != nil {
					publishErr = errors.Join(publishErr, err)
				}
			}
		}
	}

	if publishErr != nil {
		p.metrics.recordFailure()
	}

	return publishErr
}

func (p *identityPublisher) upsertIdentity(ctx context.Context, key string, payload []byte, metadataHash string, attrs map[string]string) error {
	attrsHash := identitymap.HashMetadata(attrs)

	if cached := p.cache.get(key); cached != nil {
		if cached.metadataHash == metadataHash && cached.attributesHash == attrsHash {
			identitymap.RecordKVPublish(ctx, 1, "unchanged")
			return nil
		}
		if cached.revision > 0 {
			resp, err := p.kvClient.Update(ctx, &proto.UpdateRequest{
				Key:        key,
				Value:      payload,
				Revision:   cached.revision,
				TtlSeconds: p.ttlSeconds,
			})
			if err == nil {
				p.metrics.recordPublish(1)
				identitymap.RecordKVPublish(ctx, 1, "updated")
				newRevision := uint64(0)
				if resp != nil {
					newRevision = resp.GetRevision()
				}
				p.cache.set(key, metadataHash, attrsHash, newRevision)
				p.logger.Debug().Str("key", key).Msg("Updated canonical identity entry in KV (cache fast-path)")
				return nil
			}
			if shouldRetryKV(err) {
				p.cache.delete(key)
				code := status.Code(err)
				if code == codes.AlreadyExists || code == codes.Aborted {
					identitymap.RecordKVConflict(ctx, code.String())
					p.logger.Debug().Str("key", key).Str("reason", code.String()).Msg("KV identity update conflict on cache fast-path")
				}
			} else {
				return err
			}
		}
	}

	bo := backoff.NewExponentialBackOff()
	bo.InitialInterval = identityInitialBackoff
	bo.MaxInterval = identityMaxBackoff
	bo.Multiplier = 1.6
	bo.RandomizationFactor = 0.2

	operation := func() (struct{}, error) {
		resp, err := p.kvClient.Get(ctx, &proto.GetRequest{Key: key})
		if err != nil {
			if shouldRetryKV(err) {
				return struct{}{}, err
			}
			return struct{}{}, backoff.Permanent(err)
		}

		if !resp.GetFound() {
			_, err := p.kvClient.PutIfAbsent(ctx, &proto.PutRequest{Key: key, Value: payload, TtlSeconds: p.ttlSeconds})
			if err != nil {
				if shouldRetryKV(err) {
					code := status.Code(err)
					if code == codes.AlreadyExists || code == codes.Aborted {
						identitymap.RecordKVConflict(ctx, code.String())
						p.logger.Debug().Str("key", key).Str("reason", code.String()).Msg("KV identity publish encountered conflict")
					}
					return struct{}{}, err
				}
				return struct{}{}, backoff.Permanent(err)
			}

			p.metrics.recordPublish(1)
			identitymap.RecordKVPublish(ctx, 1, "created")
			p.logger.Debug().Str("key", key).Msg("Created canonical identity entry in KV")
			p.cache.set(key, metadataHash, attrsHash, 0)
			return struct{}{}, nil
		}

		existing, err := identitymap.UnmarshalRecord(resp.GetValue())
		if err != nil {
			return struct{}{}, backoff.Permanent(fmt.Errorf("unmarshal existing canonical record: %w", err))
		}

		existingAttrsHash := identitymap.HashMetadata(existing.Attributes)
		p.cache.set(key, existing.MetadataHash, existingAttrsHash, resp.GetRevision())
		if existing.MetadataHash == metadataHash && attributesEqual(existing.Attributes, attrs) {
			identitymap.RecordKVPublish(ctx, 1, "unchanged")
			return struct{}{}, nil
		}

		updateResp, err := p.kvClient.Update(ctx, &proto.UpdateRequest{
			Key:        key,
			Value:      payload,
			Revision:   resp.GetRevision(),
			TtlSeconds: p.ttlSeconds,
		})
		if err != nil {
			if shouldRetryKV(err) {
				code := status.Code(err)
				if code == codes.AlreadyExists || code == codes.Aborted {
					identitymap.RecordKVConflict(ctx, code.String())
					p.logger.Debug().Str("key", key).Str("reason", code.String()).Msg("KV identity update encountered conflict")
				}
				p.cache.delete(key)
				return struct{}{}, err
			}
			return struct{}{}, backoff.Permanent(err)
		}

		p.metrics.recordPublish(1)
		identitymap.RecordKVPublish(ctx, 1, "updated")
		p.logger.Debug().Str("key", key).Msg("Updated canonical identity entry in KV")
		var newRevision uint64
		if updateResp != nil {
			newRevision = updateResp.GetRevision()
		}
		p.cache.set(key, metadataHash, attrsHash, newRevision)
		return struct{}{}, nil
	}

	if _, err := backoff.Retry(ctx, operation, backoff.WithBackOff(bo), backoff.WithMaxElapsedTime(identityMaxElapsed)); err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return err
		}
		identitymap.RecordKVConflict(ctx, "retry_exhausted")
		p.logger.Warn().Str("key", key).Err(err).Msg("KV identity publish exhausted retries")
		return fmt.Errorf("publish identity key %s: %w", key, err)
	}

	return nil
}

func shouldRetryKV(err error) bool {
	if err == nil {
		return false
	}

	//exhaustive:ignore
	switch status.Code(err) {
	case codes.OK:
		return false
	case codes.AlreadyExists, codes.Aborted, codes.Unavailable, codes.ResourceExhausted, codes.DeadlineExceeded, codes.Internal:
		return true
	default:
		return false
	}
}

func shouldSkipIdentityPublish(update *models.DeviceUpdate) bool {
	if update == nil {
		return true
	}
	if update.DeviceID == "" {
		return true
	}
	if update.Source == models.DiscoverySourceSweep {
		return true
	}
	if update.Metadata != nil {
		if deleted, ok := update.Metadata["_deleted"]; ok && strings.EqualFold(deleted, "true") {
			return true
		}
	}
	return false
}

func buildIdentityAttributes(update *models.DeviceUpdate) map[string]string {
	attrs := map[string]string{}
	if update == nil {
		return nil
	}

	if update.IP != "" {
		attrs["ip"] = update.IP
	}
	if update.Partition != "" {
		attrs["partition"] = update.Partition
	}
	if update.Hostname != nil && strings.TrimSpace(*update.Hostname) != "" {
		attrs["hostname"] = strings.TrimSpace(*update.Hostname)
	}
	if src := strings.TrimSpace(string(update.Source)); src != "" {
		attrs["source"] = src
	}
	if update.Metadata != nil {
		if armis := strings.TrimSpace(update.Metadata["armis_device_id"]); armis != "" {
			attrs["armis_device_id"] = armis
		}
		if integration := strings.TrimSpace(update.Metadata["integration_id"]); integration != "" {
			attrs["integration_id"] = integration
		}
		if netbox := strings.TrimSpace(update.Metadata["netbox_device_id"]); netbox != "" {
			attrs["netbox_device_id"] = netbox
		}
		if typ := strings.TrimSpace(update.Metadata["integration_type"]); typ != "" {
			attrs["integration_type"] = typ
		}
	}
	if update.MAC != nil {
		mac := strings.TrimSpace(*update.MAC)
		if mac != "" {
			attrs["mac"] = strings.ToUpper(mac)
		}
	}
	if len(attrs) == 0 {
		return nil
	}
	return attrs
}

func attributesEqual(existing, desired map[string]string) bool {
	if len(desired) == 0 {
		return len(existing) == 0
	}
	for key, val := range desired {
		if strings.TrimSpace(val) == "" {
			continue
		}
		if strings.TrimSpace(existing[key]) != strings.TrimSpace(val) {
			return false
		}
	}
	return true
}

func (r *DeviceRegistry) publishIdentityMap(ctx context.Context, updates []*models.DeviceUpdate) {
	if r.identityPublisher == nil {
		return
	}
	if err := r.identityPublisher.Publish(ctx, updates); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to publish identity map updates")
	}
}

type identitySnapshot struct {
	keys         map[string]struct{}
	canonicalKey string
	metadataHash string
	attrsHash    string
	revision     uint64
}

func (s *identitySnapshot) staleKeys(newKeys map[string]struct{}) []string {
	if s == nil || len(s.keys) == 0 {
		return nil
	}

	stale := make([]string, 0, len(s.keys))
	for key := range s.keys {
		if _, ok := newKeys[key]; !ok {
			stale = append(stale, key)
		}
	}
	return stale
}

func (p *identityPublisher) existingIdentitySnapshot(ctx context.Context, deviceID string) (*identitySnapshot, error) {
	if p == nil || p.kvClient == nil || strings.TrimSpace(deviceID) == "" {
		return nil, nil
	}

	key := identitymap.Key{Kind: identitymap.KindDeviceID, Value: deviceID}.KeyPath(p.namespace)
	resp, err := p.kvClient.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return nil, err
	}
	if !resp.GetFound() || len(resp.GetValue()) == 0 {
		return nil, nil
	}

	record, err := identitymap.UnmarshalRecord(resp.GetValue())
	if err != nil {
		return nil, fmt.Errorf("unmarshal canonical record for device %s: %w", deviceID, err)
	}

	keys := identitymap.BuildKeysFromRecord(record)
	keySet := make(map[string]struct{}, len(keys))
	for _, identityKey := range keys {
		keySet[identityKey.KeyPath(p.namespace)] = struct{}{}
	}

	return &identitySnapshot{
		keys:         keySet,
		canonicalKey: key,
		metadataHash: record.MetadataHash,
		attrsHash:    identitymap.HashMetadata(record.Attributes),
		revision:     resp.GetRevision(),
	}, nil
}

func (p *identityPublisher) deleteIdentityKeys(ctx context.Context, keys []string) error {
	if p == nil || p.kvClient == nil || len(keys) == 0 {
		return nil
	}

	var deleteErr error
	var deletedCount int

	for _, key := range keys {
		if strings.TrimSpace(key) == "" {
			continue
		}

		_, err := p.kvClient.Delete(ctx, &proto.DeleteRequest{Key: key})
		if err != nil {
			if st, ok := status.FromError(err); ok && st.Code() == codes.NotFound {
				p.logger.Debug().Str("key", key).Msg("Stale identity key already removed from KV")
				p.cache.delete(key)
				continue
			}
			deleteErr = errors.Join(deleteErr, err)
			continue
		}

		deletedCount++
		p.cache.delete(key)
		p.logger.Debug().Str("key", key).Msg("Deleted stale identity entry from KV")
	}

	if deletedCount > 0 {
		p.metrics.recordDelete(deletedCount)
	}

	return deleteErr
}
