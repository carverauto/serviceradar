package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	"google.golang.org/grpc"
	grpccodes "google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errDBServiceUnavailable    = errors.New("identity lookup: database service not configured")
	errUnsupportedIdentityKind = errors.New("identity lookup: unsupported identity kind")
)

type identityKVClient interface {
	Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	PutIfAbsent(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	Update(ctx context.Context, in *proto.UpdateRequest, opts ...grpc.CallOption) (*proto.UpdateResponse, error)
}

// GetCanonicalDevice resolves a set of identity keys to the canonical device record maintained in KV.
func (s *Server) GetCanonicalDevice(ctx context.Context, req *proto.GetCanonicalDeviceRequest) (*proto.GetCanonicalDeviceResponse, error) {
	ctx, span := s.tracer.Start(ctx, "GetCanonicalDevice")
	defer span.End()

	if req == nil || len(req.GetIdentityKeys()) == 0 && strings.TrimSpace(req.GetIpHint()) == "" {
		span.SetStatus(otelcodes.Error, "missing identity keys")
		return nil, status.Error(grpccodes.InvalidArgument, "identity keys are required")
	}

	namespace := strings.TrimSpace(req.GetNamespace())
	if namespace == "" {
		namespace = identitymap.DefaultNamespace
	}

	span.SetAttributes(
		attribute.Int("identity.count", len(req.GetIdentityKeys())),
		attribute.String("namespace", namespace),
	)

	// Normalize identity keys and append optional IP hint if provided.
	keys := normalizeIdentityKeys(req)

	// Attempt KV lookups in order.
	for _, key := range keys {
		rec, revision, err := s.lookupIdentityFromKV(ctx, namespace, key)
		if err != nil {
			s.logger.Warn().Err(err).Str("key", key.KeyPath(namespace)).Msg("identity KV lookup failed")
			span.RecordError(err)
			continue
		}
		if rec != nil {
			span.SetStatus(otelcodes.Ok, "resolved via kv")
			return &proto.GetCanonicalDeviceResponse{
				Found:      true,
				Record:     rec.ToProto(),
				MatchedKey: key.ToProto(),
				Revision:   revision,
			}, nil
		}
	}

	// Fallback to database correlation when KV misses.
	record, matchedKey, err := s.lookupIdentityFromDB(ctx, keys)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, err.Error())
		return nil, status.Errorf(grpccodes.Internal, "failed to resolve canonical identity: %v", err)
	}
	if record == nil {
		span.SetStatus(otelcodes.Ok, "identity not found")
		return &proto.GetCanonicalDeviceResponse{Found: false}, nil
	}

	hydrate := false
	if ok, err := s.hydrateIdentityKV(ctx, namespace, matchedKey, record); err != nil {
		// Hydration failure is logged but does not fail the lookup response.
		s.logger.Warn().Err(err).Str("key", matchedKey.KeyPath(namespace)).Msg("failed to hydrate identity kv")
		span.RecordError(err)
	} else {
		hydrate = ok
	}

	span.SetStatus(otelcodes.Ok, "resolved via db fallback")
	return &proto.GetCanonicalDeviceResponse{
		Found:      true,
		Record:     record.ToProto(),
		MatchedKey: matchedKey.ToProto(),
		Hydrated:   hydrate,
	}, nil
}

func (s *Server) lookupIdentityFromKV(ctx context.Context, namespace string, key identitymap.Key) (*identitymap.Record, uint64, error) {
	if s.identityKVClient == nil {
		return nil, 0, nil
	}
	resp, err := s.identityKVClient.Get(ctx, &proto.GetRequest{Key: key.KeyPath(namespace)})
	if err != nil {
		return nil, 0, err
	}
	if !resp.GetFound() || len(resp.GetValue()) == 0 {
		return nil, resp.GetRevision(), nil
	}
	rec, err := identitymap.UnmarshalRecord(resp.GetValue())
	if err != nil {
		return nil, 0, err
	}
	return rec, resp.GetRevision(), nil
}

func (s *Server) lookupIdentityFromDB(ctx context.Context, keys []identitymap.Key) (*identitymap.Record, identitymap.Key, error) {
	if s.DB == nil {
		return nil, identitymap.Key{}, errDBServiceUnavailable
	}

	for _, key := range keys {
		device, err := s.fetchCanonicalDevice(ctx, key)
		if err != nil {
			s.logger.Debug().Err(err).Str("identity", key.Value).Int("kind", int(key.Kind)).Msg("identity lookup miss")
			continue
		}
		if device == nil {
			continue
		}

		record := buildRecordFromUnifiedDevice(device)
		if record == nil {
			continue
		}
		// Update timestamp to mark hydration moment.
		record.UpdatedAt = time.Now().UTC()
		return record, key, nil
	}

	return nil, identitymap.Key{}, nil
}

func (s *Server) fetchCanonicalDevice(ctx context.Context, key identitymap.Key) (*models.UnifiedDevice, error) {
	switch key.Kind {
	case identitymap.KindDeviceID:
		return s.DB.GetUnifiedDevice(ctx, key.Value)
	case identitymap.KindPartitionIP:
		partition, ip := splitPartitionIP(key.Value)
		devices, err := s.DB.GetUnifiedDevicesByIPsOrIDs(ctx, []string{ip}, nil)
		if err != nil {
			return nil, err
		}
		return selectPartitionMatch(devices, partition), nil
	case identitymap.KindIP:
		devices, err := s.DB.GetUnifiedDevicesByIPsOrIDs(ctx, []string{key.Value}, nil)
		if err != nil {
			return nil, err
		}
		return selectCanonicalDevice(devices), nil
	case identitymap.KindMAC:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, macLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetUnifiedDevice(ctx, deviceID)
	case identitymap.KindArmisID:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, armisLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetUnifiedDevice(ctx, deviceID)
	case identitymap.KindNetboxID:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, netboxLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetUnifiedDevice(ctx, deviceID)
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedIdentityKind, key.Kind.String())
	}
}

func (s *Server) lookupDeviceIDByQuery(ctx context.Context, query string) (string, error) {
	if query == "" {
		return "", nil
	}
	rows, err := s.DB.ExecuteQuery(ctx, query)
	if err != nil {
		return "", err
	}
	if len(rows) == 0 {
		return "", nil
	}
	id, _ := rows[0]["device_id"].(string)
	return id, nil
}

func (s *Server) hydrateIdentityKV(ctx context.Context, namespace string, key identitymap.Key, record *identitymap.Record) (bool, error) {
	if s.identityKVClient == nil || record == nil {
		return false, nil
	}

	payload, err := identitymap.MarshalRecord(record)
	if err != nil {
		return false, err
	}

	_, err = s.identityKVClient.PutIfAbsent(ctx, &proto.PutRequest{Key: key.KeyPath(namespace), Value: payload})
	if err == nil {
		return true, nil
	}

	//exhaustive:ignore
	switch status.Code(err) {
	case grpccodes.AlreadyExists:
		resp, getErr := s.identityKVClient.Get(ctx, &proto.GetRequest{Key: key.KeyPath(namespace)})
		if getErr != nil {
			return false, getErr
		}
		existing, unmarshalErr := identitymap.UnmarshalRecord(resp.GetValue())
		if unmarshalErr != nil {
			return false, unmarshalErr
		}
		if existing.MetadataHash == record.MetadataHash {
			return false, nil
		}
		_, updErr := s.identityKVClient.Update(ctx, &proto.UpdateRequest{
			Key:        key.KeyPath(namespace),
			Value:      payload,
			Revision:   resp.GetRevision(),
			TtlSeconds: 0,
		})
		if updErr != nil {
			if status.Code(updErr) == grpccodes.Aborted {
				return false, nil
			}
			return false, updErr
		}
		return true, nil
	case grpccodes.Unimplemented:
		return false, nil
	default:
		return false, err
	}
}

func buildRecordFromUnifiedDevice(device *models.UnifiedDevice) *identitymap.Record {
	if device == nil {
		return nil
	}

	attrs := map[string]string{}
	if device.IP != "" {
		attrs["ip"] = device.IP
	}
	partition := partitionFromDeviceID(device.DeviceID)
	if partition != "" {
		attrs["partition"] = partition
	}
	if device.Hostname != nil {
		if name := strings.TrimSpace(device.Hostname.Value); name != "" {
			attrs["hostname"] = name
		}
	}
	if len(device.DiscoverySources) > 0 {
		src := strings.TrimSpace(string(device.DiscoverySources[0].Source))
		if src != "" {
			attrs["source"] = src
		}
	}
	if len(attrs) == 0 {
		attrs = nil
	}

	metadata := map[string]string{}
	if device.Metadata != nil && len(device.Metadata.Value) > 0 {
		metadata = device.Metadata.Value
	}

	return &identitymap.Record{
		CanonicalDeviceID: device.DeviceID,
		Partition:         partition,
		MetadataHash:      identitymap.HashMetadata(metadata),
		Attributes:        attrs,
	}
}

func selectCanonicalDevice(devices []*models.UnifiedDevice) *models.UnifiedDevice {
	if len(devices) == 0 {
		return nil
	}
	for _, device := range devices {
		if device == nil {
			continue
		}
		if device.Metadata != nil {
			if _, tombstoned := device.Metadata.Value["_merged_into"]; tombstoned {
				continue
			}
			if deleted, ok := device.Metadata.Value["_deleted"]; ok && strings.EqualFold(deleted, "true") {
				continue
			}
		}
		return device
	}
	return devices[0]
}

func selectPartitionMatch(devices []*models.UnifiedDevice, partition string) *models.UnifiedDevice {
	if len(devices) == 0 {
		return nil
	}
	for _, device := range devices {
		if device == nil {
			continue
		}
		if partition != "" && partitionFromDeviceID(device.DeviceID) == partition {
			return device
		}
	}
	return selectCanonicalDevice(devices)
}

func splitPartitionIP(value string) (string, string) {
	parts := strings.SplitN(value, ":", 2)
	if len(parts) != 2 {
		return "", value
	}
	return parts[0], parts[1]
}

func normalizeIdentityKeys(req *proto.GetCanonicalDeviceRequest) []identitymap.Key {
	keys := make([]identitymap.Key, 0, len(req.GetIdentityKeys())+1)
	seen := make(map[string]struct{})
	for _, pb := range req.GetIdentityKeys() {
		key := identitymap.FromProtoKey(pb)
		if key.Kind == identitymap.KindUnspecified || strings.TrimSpace(key.Value) == "" {
			continue
		}
		signature := fmt.Sprintf("%d|%s", key.Kind, key.Value)
		if _, ok := seen[signature]; ok {
			continue
		}
		seen[signature] = struct{}{}
		keys = append(keys, key)
	}

	if ip := strings.TrimSpace(req.GetIpHint()); ip != "" {
		signature := fmt.Sprintf("%d|%s", identitymap.KindIP, ip)
		if _, ok := seen[signature]; !ok {
			keys = append(keys, identitymap.Key{Kind: identitymap.KindIP, Value: ip})
		}
	}
	return keys
}

func escapeLiteral(value string) string {
	return strings.ReplaceAll(value, "'", "''")
}

func macLookupQuery(mac string) string {
	mac = strings.TrimSpace(mac)
	if mac == "" {
		return ""
	}
	return fmt.Sprintf(`SELECT device_id FROM table(unified_devices)
            WHERE mac = '%s'
            ORDER BY _tp_time DESC
            LIMIT 1`, escapeLiteral(mac))
}

func armisLookupQuery(armis string) string {
	armis = strings.TrimSpace(armis)
	if armis == "" {
		return ""
	}
	return fmt.Sprintf(`SELECT device_id
            FROM table(unified_devices)
            WHERE has(map_keys(metadata), 'armis_device_id')
              AND metadata['armis_device_id'] = '%s'
            ORDER BY _tp_time DESC
            LIMIT 1`, escapeLiteral(armis))
}

func netboxLookupQuery(id string) string {
	id = strings.TrimSpace(id)
	if id == "" {
		return ""
	}
	esc := escapeLiteral(id)
	return fmt.Sprintf(`SELECT device_id
            FROM table(unified_devices)
            WHERE has(map_keys(metadata), 'integration_type')
              AND metadata['integration_type'] = 'netbox'
              AND ((has(map_keys(metadata), 'integration_id') AND metadata['integration_id'] = '%s')
                OR (has(map_keys(metadata), 'netbox_device_id') = 1 AND metadata['netbox_device_id'] = '%s'))
            ORDER BY _tp_time DESC
            LIMIT 1`, esc, esc)
}
