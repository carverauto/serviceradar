package registry

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

type kvPutManyClient interface {
	PutMany(ctx context.Context, in *proto.PutManyRequest, opts ...grpc.CallOption) (*proto.PutManyResponse, error)
}

type identityPublisher struct {
	client     kvPutManyClient
	namespace  string
	ttlSeconds int64
	metrics    *identityPublisherMetrics
	logger     logger.Logger
}

// WithIdentityPublisher wires a KV-backed identity map publisher into the device registry.
func WithIdentityPublisher(client kvPutManyClient, namespace string, ttl time.Duration) Option {
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
	failures       atomic.Int64
}

func newIdentityPublisherMetrics() *identityPublisherMetrics {
	return &identityPublisherMetrics{}
}

func (m *identityPublisherMetrics) recordPublish(keyCount int) {
	m.publishBatches.Add(1)
	m.publishedKeys.Add(int64(keyCount))
}

func (m *identityPublisherMetrics) recordFailure() {
	m.failures.Add(1)
}

func newIdentityPublisher(client kvPutManyClient, namespace string, ttl time.Duration, log logger.Logger) *identityPublisher {
	if client == nil {
		return nil
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = identitymap.DefaultNamespace
	}
	return &identityPublisher{
		client:     client,
		namespace:  ns,
		ttlSeconds: int64(ttl / time.Second),
		metrics:    newIdentityPublisherMetrics(),
		logger:     log,
	}
}

func (p *identityPublisher) Publish(ctx context.Context, updates []*models.DeviceUpdate) error {
	if p == nil || p.client == nil || len(updates) == 0 {
		return nil
	}

	now := time.Now().UTC()
	entries := make(map[string][]byte)
	var publishErr error

	for _, update := range updates {
		if update == nil {
			continue
		}
		if shouldSkipIdentityPublish(update) {
			continue
		}

		record := &identitymap.Record{
			CanonicalDeviceID: update.DeviceID,
			Partition:         update.Partition,
			MetadataHash:      identitymap.HashMetadata(update.Metadata),
			UpdatedAt:         now,
			Attributes:        buildIdentityAttributes(update),
		}

		payload, err := identitymap.MarshalRecord(record)
		if err != nil {
			publishErr = errors.Join(publishErr, fmt.Errorf("marshal canonical record: %w", err))
			continue
		}

		keys := identitymap.BuildKeys(update)
		if len(keys) == 0 {
			continue
		}

		for _, key := range keys {
			entries[key.KeyPath(p.namespace)] = payload
		}
	}

	if len(entries) == 0 {
		if publishErr != nil {
			p.metrics.recordFailure()
		}
		return publishErr
	}

	req := &proto.PutManyRequest{
		Entries:    make([]*proto.KeyValueEntry, 0, len(entries)),
		TtlSeconds: p.ttlSeconds,
	}

	for key, value := range entries {
		copied := make([]byte, len(value))
		copy(copied, value)
		req.Entries = append(req.Entries, &proto.KeyValueEntry{Key: key, Value: copied})
	}

	if _, err := p.client.PutMany(ctx, req); err != nil {
		publishErr = errors.Join(publishErr, fmt.Errorf("kv putmany: %w", err))
		p.metrics.recordFailure()
		return publishErr
	}

	p.metrics.recordPublish(len(req.Entries))
	p.logger.Debug().
		Int("key_count", len(req.Entries)).
		Msg("Published canonical identity entries to KV")

	return publishErr
}

func shouldSkipIdentityPublish(update *models.DeviceUpdate) bool {
	if update == nil {
		return true
	}
	if update.DeviceID == "" {
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
	if len(attrs) == 0 {
		return nil
	}
	return attrs
}

func (r *DeviceRegistry) publishIdentityMap(ctx context.Context, updates []*models.DeviceUpdate) {
	if r.identityPublisher == nil {
		return
	}
	if err := r.identityPublisher.Publish(ctx, updates); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to publish identity map updates")
	}
}
