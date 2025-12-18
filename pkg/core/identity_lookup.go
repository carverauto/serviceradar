package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
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

// GetCanonicalDevice resolves a set of identity keys to the canonical device record via CNPG.
// KV is not used for identity resolution - CNPG is the authoritative source.
func (s *Server) GetCanonicalDevice(ctx context.Context, req *proto.GetCanonicalDeviceRequest) (*proto.GetCanonicalDeviceResponse, error) {
	ctx, span := s.tracer.Start(ctx, "GetCanonicalDevice")
	defer span.End()

	start := time.Now()
	resolvedVia := "error"
	found := false
	defer func() {
		identitymap.RecordLookupLatency(ctx, time.Since(start), resolvedVia, found)
	}()

	if req == nil || len(req.GetIdentityKeys()) == 0 && strings.TrimSpace(req.GetIpHint()) == "" {
		span.SetStatus(otelcodes.Error, "missing identity keys")
		return nil, status.Error(grpccodes.InvalidArgument, "identity keys are required")
	}

	span.SetAttributes(
		attribute.Int("identity.count", len(req.GetIdentityKeys())),
	)

	// Normalize identity keys and append optional IP hint if provided.
	keys := normalizeIdentityKeys(req)

	// Resolve via CNPG-backed database lookup.
	record, matchedKey, err := s.lookupIdentityFromDB(ctx, keys)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, err.Error())
		return nil, status.Errorf(grpccodes.Internal, "failed to resolve canonical identity: %v", err)
	}
	if record == nil {
		span.SetStatus(otelcodes.Ok, "identity not found")
		resolvedVia = "miss"
		return &proto.GetCanonicalDeviceResponse{Found: false}, nil
	}

	span.SetStatus(otelcodes.Ok, "resolved via db")
	resolvedVia = "db"
	found = true
	return &proto.GetCanonicalDeviceResponse{
		Found:      true,
		Record:     record.ToProto(),
		MatchedKey: matchedKey.ToProto(),
	}, nil
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

		record := buildRecordFromOCSFDevice(device)
		if record == nil {
			continue
		}
		// Update timestamp to mark hydration moment.
		record.UpdatedAt = time.Now().UTC()
		return record, key, nil
	}

	return nil, identitymap.Key{}, nil
}

func (s *Server) fetchCanonicalDevice(ctx context.Context, key identitymap.Key) (*models.OCSFDevice, error) {
	switch key.Kind {
	case identitymap.KindDeviceID:
		return s.DB.GetOCSFDevice(ctx, key.Value)
	case identitymap.KindPartitionIP:
		partition, ip := splitPartitionIP(key.Value)
		devices, err := s.DB.GetOCSFDevicesByIPsOrIDs(ctx, []string{ip}, nil)
		if err != nil {
			return nil, err
		}
		return selectPartitionMatch(devices, partition), nil
	case identitymap.KindIP:
		devices, err := s.DB.GetOCSFDevicesByIPsOrIDs(ctx, []string{key.Value}, nil)
		if err != nil {
			return nil, err
		}
		return selectCanonicalDevice(devices), nil
	case identitymap.KindMAC:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, macLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetOCSFDevice(ctx, deviceID)
	case identitymap.KindArmisID:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, armisLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetOCSFDevice(ctx, deviceID)
	case identitymap.KindNetboxID:
		deviceID, err := s.lookupDeviceIDByQuery(ctx, netboxLookupQuery(key.Value))
		if err != nil || deviceID == "" {
			return nil, err
		}
		return s.DB.GetOCSFDevice(ctx, deviceID)
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
	id, _ := rows[0]["uid"].(string)
	return id, nil
}

func buildRecordFromOCSFDevice(device *models.OCSFDevice) *identitymap.Record {
	if device == nil {
		return nil
	}

	attrs := map[string]string{}
	if device.IP != "" {
		attrs["ip"] = device.IP
	}
	partition := partitionFromDeviceID(device.UID)
	if partition != "" {
		attrs["partition"] = partition
	}
	if name := strings.TrimSpace(device.Hostname); name != "" {
		attrs["hostname"] = name
	}
	if device.Metadata != nil {
		if src := strings.TrimSpace(device.Metadata["discovery_source"]); src != "" {
			attrs["source"] = src
		}
	}
	if len(attrs) == 0 {
		attrs = nil
	}

	metadata := map[string]string{}
	if len(device.Metadata) > 0 {
		metadata = device.Metadata
	}

	update := &models.DeviceUpdate{
		DeviceID:  device.UID,
		Partition: partition,
		IP:        device.IP,
		Metadata:  metadata,
	}

	if device.Metadata != nil {
		if src := strings.TrimSpace(device.Metadata["discovery_source"]); src != "" {
			update.Source = models.DiscoverySource(src)
		}
	}
	if hostname := strings.TrimSpace(device.Hostname); hostname != "" {
		update.Hostname = &hostname
	}
	if mac := strings.TrimSpace(device.MAC); mac != "" {
		update.MAC = &mac
	}

	return &identitymap.Record{
		CanonicalDeviceID: device.UID,
		Partition:         partition,
		MetadataHash:      identitymap.HashIdentityMetadata(update),
		Attributes:        attrs,
	}
}

func selectCanonicalDevice(devices []*models.OCSFDevice) *models.OCSFDevice {
	if len(devices) == 0 {
		return nil
	}
	for _, device := range devices {
		if device == nil {
			continue
		}
		if device.Metadata != nil {
			if _, tombstoned := device.Metadata["_merged_into"]; tombstoned {
				continue
			}
			if deleted, ok := device.Metadata["_deleted"]; ok && strings.EqualFold(deleted, "true") {
				continue
			}
		}
		return device
	}
	return devices[0]
}

func selectPartitionMatch(devices []*models.OCSFDevice, partition string) *models.OCSFDevice {
	if len(devices) == 0 {
		return nil
	}
	for _, device := range devices {
		if device == nil {
			continue
		}
		if partition != "" && partitionFromDeviceID(device.UID) == partition {
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
	return fmt.Sprintf(`SELECT uid FROM ocsf_devices
            WHERE mac = '%s'
            ORDER BY modified_time DESC
            LIMIT 1`, escapeLiteral(mac))
}

func armisLookupQuery(armis string) string {
	armis = strings.TrimSpace(armis)
	if armis == "" {
		return ""
	}
	return fmt.Sprintf(`SELECT uid
            FROM ocsf_devices
            WHERE metadata ? 'armis_device_id'
              AND metadata->>'armis_device_id' = '%s'
            ORDER BY modified_time DESC
            LIMIT 1`, escapeLiteral(armis))
}

func netboxLookupQuery(id string) string {
	id = strings.TrimSpace(id)
	if id == "" {
		return ""
	}
	esc := escapeLiteral(id)
	return fmt.Sprintf(`SELECT uid
            FROM ocsf_devices
            WHERE metadata ? 'integration_type'
              AND metadata->>'integration_type' = 'netbox'
              AND ((metadata ? 'integration_id' AND metadata->>'integration_id' = '%s')
                OR (metadata ? 'netbox_device_id' AND metadata->>'netbox_device_id' = '%s'))
            ORDER BY modified_time DESC
            LIMIT 1`, esc, esc)
}

// partitionFromDeviceID extracts the partition prefix from a device ID.
// Device IDs have the format "partition:ip" or similar compound keys.
func partitionFromDeviceID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 {
		return parts[0]
	}
	return "default"
}
