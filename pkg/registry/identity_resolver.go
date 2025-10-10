package registry

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	canonicalKVBatchChunkSize   = 256
	canonicalKVFetchConcurrency = 8
)

type kvBatchGetter interface {
	BatchGet(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error)
}

type identityResolver struct {
	kv        kvBatchGetter
	namespace string
	logger    logger.Logger
}

// WithIdentityResolver wires a KV-backed canonical resolver into the device registry.
func WithIdentityResolver(client kvBatchGetter, namespace string) Option {
	return func(r *DeviceRegistry) {
		if r == nil || client == nil {
			return
		}
		ns := namespace
		if ns == "" {
			ns = identitymap.DefaultNamespace
		}
		r.identityResolver = &identityResolver{
			kv:        client,
			namespace: ns,
			logger:    r.logger,
		}
	}
}

func (r *identityResolver) hydrateCanonical(ctx context.Context, updates []*models.DeviceUpdate) error {
	if r == nil || r.kv == nil || len(updates) == 0 {
		return nil
	}

	paths := collectIdentityPaths(updates, r.namespace)
	if len(paths) == 0 {
		return nil
	}

	entries, fetchErr := r.fetchCanonicalEntries(ctx, paths)
	if len(entries) == 0 {
		return fetchErr
	}

	hydrated := 0
	for _, update := range updates {
		if update == nil {
			continue
		}

		if hydrateUpdateFromEntries(update, entries, r.namespace) {
			hydrated++
		}
	}

	if hydrated > 0 {
		r.logger.Debug().
			Int("updates_hydrated", hydrated).
			Int("unique_identity_paths", len(entries)).
			Msg("Applied canonical identifiers from KV")
	}

	return fetchErr
}

func (r *identityResolver) fetchCanonicalEntries(ctx context.Context, paths []string) (map[string]canonicalEntry, error) {
	entries := make(map[string]canonicalEntry, len(paths))
	var joinErr error

	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(canonicalKVFetchConcurrency)

	var mu sync.Mutex
	var errMu sync.Mutex

	for start := 0; start < len(paths); start += canonicalKVBatchChunkSize {
		end := start + canonicalKVBatchChunkSize
		if end > len(paths) {
			end = len(paths)
		}

		batch := append([]string(nil), paths[start:end]...)
		g.Go(func() error {
			batchEntries, err := r.fetchBatch(ctx, batch)
			if len(batchEntries) > 0 {
				mu.Lock()
				for k, v := range batchEntries {
					entries[k] = v
				}
				mu.Unlock()
			}
			if err != nil {
				errMu.Lock()
				joinErr = errors.Join(joinErr, err)
				errMu.Unlock()
			}
			return err
		})
	}

	if err := g.Wait(); err != nil && joinErr == nil {
		joinErr = err
	}

	return entries, joinErr
}

func (r *identityResolver) fetchBatch(ctx context.Context, keys []string) (map[string]canonicalEntry, error) {
	resp, err := r.kv.BatchGet(ctx, &proto.BatchGetRequest{Keys: keys})
	if err != nil {
		if st, ok := status.FromError(err); ok && (st.Code() == codes.ResourceExhausted || st.Code() == codes.OutOfRange) && len(keys) > 1 {
			mid := len(keys) / 2
			if mid == 0 {
				mid = 1
			}

			left, leftErr := r.fetchBatch(ctx, keys[:mid])
			right, rightErr := r.fetchBatch(ctx, keys[mid:])

			results := make(map[string]canonicalEntry, len(left)+len(right))
			for k, v := range left {
				results[k] = v
			}
			for k, v := range right {
				results[k] = v
			}
			return results, errors.Join(leftErr, rightErr)
		}
		return nil, err
	}

	results := make(map[string]canonicalEntry, len(resp.GetResults()))
	for _, entry := range resp.GetResults() {
		if entry == nil || !entry.GetFound() || len(entry.GetValue()) == 0 {
			continue
		}
		record, err := identitymap.UnmarshalRecord(entry.GetValue())
		if err != nil {
			r.logger.Debug().Err(err).Str("key", entry.GetKey()).Msg("Failed to unmarshal canonical record")
			continue
		}
		results[entry.GetKey()] = canonicalEntry{
			record:   record,
			revision: entry.GetRevision(),
		}
	}

	return results, nil
}

type canonicalEntry struct {
	record   *identitymap.Record
	revision uint64
}

func collectIdentityPaths(updates []*models.DeviceUpdate, namespace string) []string {
	if len(updates) == 0 {
		return nil
	}
	unique := make(map[string]struct{})
	paths := make([]string, 0)

	for _, update := range updates {
		if update == nil {
			continue
		}
		for _, key := range identitymap.BuildKeys(update) {
			for _, variant := range key.KeyPathVariants(namespace) {
				sanitized := identitymap.SanitizeKeyPath(variant)
				if sanitized == "" {
					continue
				}
				if _, exists := unique[sanitized]; exists {
					continue
				}
				unique[sanitized] = struct{}{}
				paths = append(paths, sanitized)
			}
		}
	}

	return paths
}

func hydrateUpdateFromEntries(update *models.DeviceUpdate, entries map[string]canonicalEntry, namespace string) bool {
	keys := identitymap.BuildKeys(update)
	if len(keys) == 0 {
		return false
	}

	record, revision := findCanonicalRecord(keys, entries, namespace)
	if record == nil {
		return false
	}

	attachCanonicalMetadataToUpdate(update, record, revision)
	return true
}

func findCanonicalRecord(keys []identitymap.Key, entries map[string]canonicalEntry, namespace string) (*identitymap.Record, uint64) {
	if len(keys) == 0 || len(entries) == 0 {
		return nil, 0
	}
	ordered := identitymap.PrioritizeKeys(keys)
	for _, key := range ordered {
		for _, variant := range key.KeyPathVariants(namespace) {
			if entry, ok := entries[identitymap.SanitizeKeyPath(variant)]; ok && entry.record != nil {
				return entry.record, entry.revision
			}
		}
	}
	return nil, 0
}

func attachCanonicalMetadataToUpdate(update *models.DeviceUpdate, record *identitymap.Record, revision uint64) {
	if update == nil || record == nil {
		return
	}

	if update.Partition == "" && record.Partition != "" {
		update.Partition = record.Partition
	}
	if record.CanonicalDeviceID != "" {
		update.DeviceID = record.CanonicalDeviceID
	}

	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}
	if record.CanonicalDeviceID != "" {
		update.Metadata["canonical_device_id"] = record.CanonicalDeviceID
	}
	if record.Partition != "" {
		update.Metadata["canonical_partition"] = record.Partition
	}
	if record.MetadataHash != "" {
		update.Metadata["canonical_metadata_hash"] = record.MetadataHash
	}
	if hostname, ok := record.Attributes["hostname"]; ok && hostname != "" {
		update.Metadata["canonical_hostname"] = hostname
	}
	if record.Attributes != nil {
		copyAttr := func(key string) {
			if update.Metadata == nil {
				update.Metadata = make(map[string]string)
			}
			if existing := strings.TrimSpace(update.Metadata[key]); existing != "" {
				return
			}
			if v, ok := record.Attributes[key]; ok && strings.TrimSpace(v) != "" {
				update.Metadata[key] = strings.TrimSpace(v)
			}
		}
		copyAttr("armis_device_id")
		copyAttr("integration_id")
		copyAttr("integration_type")
		copyAttr("netbox_device_id")
		copyAttr("mac")

		if macAttr, ok := record.Attributes["mac"]; ok && strings.TrimSpace(macAttr) != "" {
			macUpper := strings.ToUpper(strings.TrimSpace(macAttr))
			if update.MAC == nil || strings.TrimSpace(*update.MAC) == "" {
				update.MAC = &macUpper
			}
		}
	}
	if revision != 0 {
		update.Metadata["canonical_revision"] = strconv.FormatUint(revision, 10)
	}
}
