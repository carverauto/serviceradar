package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func buildPluginResult(snapshot Snapshot, maxResultBytes int) (*sdk.Result, error) {
	discovery := sdk.NewDeviceDiscovery("opentext-nom")
	discovery.CollectionID = snapshot.CollectionID
	discovery.ObservedAt = snapshot.ObservedAt.UTC().Format(time.RFC3339Nano)
	discovery.ReferenceHash = snapshot.ContentHash
	discovery.Metadata = map[string]any{
		"source_instance":   snapshot.InstanceID,
		"snapshot_complete": snapshot.SnapshotComplete,
		"query_hash":        snapshot.QueryHash,
		"content_hash":      snapshot.ContentHash,
		"page_count":        snapshot.Pages,
		"received_rows":     snapshot.ReceivedRows,
		"unique_devices":    len(snapshot.Devices),
		"invalid_rows":      snapshot.InvalidRows,
		"duplicate_rows":    snapshot.DuplicateRows,
	}

	for _, device := range snapshot.Devices {
		available := managementAvailable(device.ManagementStatus, device.ExcludeFromPoll)
		discovered := sdk.DiscoveredDevice{
			DeviceID:    device.SourceObjectID,
			Hostname:    device.Hostname,
			IP:          device.IP,
			MAC:         device.MAC,
			Serial:      device.Serial,
			VendorName:  device.Vendor,
			Model:       device.Model,
			Type:        device.DeviceType,
			Status:      device.ManagementStatus,
			IsAvailable: available,
			Labels: map[string]string{
				"discovery_source": "opentext-nom",
				"inventory_source": "opentext-nom",
			},
			Metadata: device.Metadata,
		}
		if device.Partition != "" {
			discovered.Location = &sdk.DeviceLocation{SiteName: device.Partition}
		}
		discovery.AddDevice(discovered)
	}

	details, _ := json.Marshal(map[string]any{
		"collection_id":      snapshot.CollectionID,
		"content_hash":       snapshot.ContentHash,
		"devices":            len(snapshot.Devices),
		"attachment_devices": len(snapshot.AttachmentDevices),
		"duplicate_rows":     snapshot.DuplicateRows,
		"invalid_rows":       snapshot.InvalidRows,
		"pages":              snapshot.Pages,
		"received_rows":      snapshot.ReceivedRows,
	})
	result := sdk.Ok(fmt.Sprintf("OpenText NOM inventory collected: %d devices", len(snapshot.Devices))).
		WithObservedAt(snapshot.ObservedAt).
		WithLabel("source", "opentext-nom").
		WithLabel("source_instance", snapshot.InstanceID).
		WithLabel("collection_id", snapshot.CollectionID).
		WithDetails(string(details)).
		WithDeviceDiscovery(*discovery)

	if len(snapshot.AttachmentDevices) > 0 {
		l2Discovery := sdk.NewDeviceDiscovery("opentext-nom")
		l2Discovery.CollectionID = snapshot.CollectionID + "-l2"
		l2Discovery.ObservedAt = snapshot.ObservedAt.UTC().Format(time.RFC3339Nano)
		l2Discovery.Metadata = map[string]any{
			"source_instance":   snapshot.InstanceID,
			"snapshot_complete": false,
			"pass":              "attached_switch_port",
		}
		for _, device := range snapshot.AttachmentDevices {
			l2Discovery.AddDevice(sdk.DiscoveredDevice{
				DeviceID: device.SourceObjectID,
				Hostname: device.Hostname,
				IP:       device.IP,
				MAC:      device.MAC,
				Labels: map[string]string{
					"discovery_source": "opentext-nom",
					"inventory_source": "opentext-nom",
				},
				Metadata: device.Metadata,
			})
		}
		result = result.WithDeviceDiscovery(*l2Discovery)
	}

	payload, err := json.Marshal(result)
	if err != nil {
		return nil, runError("opentext_nom_result_invalid")
	}
	if len(payload) > maxResultBytes {
		return nil, runError("opentext_nom_result_too_large")
	}
	return result, nil
}

func buildConfigRetrieveResult(cfg RunningConfig, artifact *sdk.ArtifactCommitResponse) *sdk.Result {
	details, _ := json.Marshal(map[string]any{
		"kind":         "running_config",
		"config_kind":  "running",
		"source":       "opentext-nom",
		"device_id":    cfg.DeviceID,
		"device_uid":   cfg.DeviceUID,
		"content_hash": cfg.Hash,
		"artifact":     artifactMeta(artifact),
	})
	return sdk.Ok("OpenText NOM running-config retrieved").
		WithLabel("source", "opentext-nom").
		WithLabel("kind", "running_config").
		WithLabel("device_uid", cfg.DeviceUID).
		WithDetails(string(details))
}

func artifactMeta(artifact *sdk.ArtifactCommitResponse) map[string]any {
	if artifact == nil {
		return nil
	}
	return map[string]any{
		"object_key":   artifact.ObjectKey,
		"sha256":       artifact.SHA256,
		"size_bytes":   artifact.SizeBytes,
		"content_type": artifact.ContentType,
	}
}

func managementAvailable(status string, excluded *bool) *bool {
	if excluded != nil && *excluded {
		value := false
		return &value
	}
	switch status {
	case "Managed", "managed", "Active", "active", "Online", "online":
		value := true
		return &value
	case "Unmanaged", "unmanaged", "Disabled", "disabled", "Offline", "offline":
		value := false
		return &value
	default:
		return nil
	}
}
