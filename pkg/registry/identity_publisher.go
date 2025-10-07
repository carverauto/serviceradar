package registry

import (
	"context"
	"errors"
	"fmt"
	"strings"
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
}

type identityPublisher struct {
	kvClient   kvIdentityClient
	namespace  string
	ttlSeconds int64
	metrics    *identityPublisherMetrics
	logger     logger.Logger
}

const (
	identityInitialBackoff = 50 * time.Millisecond
	identityMaxBackoff     = 750 * time.Millisecond
	identityMaxElapsed     = 5 * time.Second
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
			MetadataHash:      identitymap.HashMetadata(update.Metadata),
			UpdatedAt:         now,
			Attributes:        buildIdentityAttributes(update),
		}

		payload, err := identitymap.MarshalRecord(record)
		if err != nil {
			publishErr = errors.Join(publishErr, fmt.Errorf("marshal canonical record: %w", err))
			continue
		}

		for _, key := range identitymap.BuildKeys(update) {
			keyPath := key.KeyPath(p.namespace)
			if err := p.upsertIdentity(ctx, keyPath, payload, record.MetadataHash); err != nil {
				publishErr = errors.Join(publishErr, err)
			}
		}
	}

	if publishErr != nil {
		p.metrics.recordFailure()
	}

	return publishErr
}

func (p *identityPublisher) upsertIdentity(ctx context.Context, key string, payload []byte, metadataHash string) error {
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
					return struct{}{}, err
				}
				return struct{}{}, backoff.Permanent(err)
			}

			p.metrics.recordPublish(1)
			p.logger.Debug().Str("key", key).Msg("Created canonical identity entry in KV")
			return struct{}{}, nil
		}

		existing, err := identitymap.UnmarshalRecord(resp.GetValue())
		if err != nil {
			return struct{}{}, backoff.Permanent(fmt.Errorf("unmarshal existing canonical record: %w", err))
		}
		if existing.MetadataHash == metadataHash {
			return struct{}{}, nil
		}

		_, err = p.kvClient.Update(ctx, &proto.UpdateRequest{
			Key:        key,
			Value:      payload,
			Revision:   resp.GetRevision(),
			TtlSeconds: p.ttlSeconds,
		})
		if err != nil {
			if shouldRetryKV(err) {
				return struct{}{}, err
			}
			return struct{}{}, backoff.Permanent(err)
		}

		p.metrics.recordPublish(1)
		p.logger.Debug().Str("key", key).Msg("Updated canonical identity entry in KV")
		return struct{}{}, nil
	}

	if _, err := backoff.Retry(ctx, operation, backoff.WithBackOff(bo), backoff.WithMaxElapsedTime(identityMaxElapsed)); err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return err
		}
		return fmt.Errorf("publish identity key %s: %w", key, err)
	}

	return nil
}

func shouldRetryKV(err error) bool {
	if err == nil {
		return false
	}

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
