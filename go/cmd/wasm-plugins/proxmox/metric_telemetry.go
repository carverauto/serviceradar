package main

import (
	"encoding/base64"
	"encoding/binary"
	"math"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	metricEnvelopeSchemaVersion = "serviceradar.metric.v1"
	metricPayloadKind           = "serviceradar_metrics"
)

type metricTelemetrySample struct {
	Name       string
	Value      float64
	Unit       string
	Thresholds *sdk.ThresholdSpec
}

func emitProxmoxMetricTelemetry(sourceInstance string, details proxmoxDetails) {
	now := uint64(time.Now().UTC().UnixNano())
	payload := encodeMetricBatch(metricBatch{
		Resource: metricResource{
			ServiceName: proxmoxSignalSchemaProducerID,
			ServiceType: "wasm-plugin",
			Attributes: []metricStringMapEntry{
				{Key: "plugin_id", Value: pluginID},
			},
		},
		IngestIdentity: metricIngestIdentity{
			Source:       "plugin-metrics",
			ProducerID:   proxmoxSignalSchemaProducerID,
			ProducerKind: "wasm-plugin",
		},
		EmittedAtUnixNano: now,
		ObservedAt:        now,
		Samples:           proxmoxMetricSamples(details),
	})

	err := sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     proxmoxSignalSchemaProducerID,
			SourceInstance: sourceInstance,
		},
		Records: []sdk.TelemetryRecord{{
			EventID:              "proxmox-metrics-" + strconv.FormatUint(now, 10),
			ObservedTimeUnixNano: int64(now),
			EventTimeUnixNano:    int64(now),
			PayloadKind:          metricPayloadKind,
			Payload:              base64.StdEncoding.EncodeToString(payload),
		}},
	})
	if err != nil {
		sdk.Log.Warn("failed to emit proxmox metric telemetry: " + err.Error())
	}
}

func proxmoxMetricSamples(details proxmoxDetails) []metricTelemetrySample {
	return []metricTelemetrySample{
		{Name: "proxmox_targets", Value: float64(details.Summary.Targets), Unit: "count"},
		{Name: "proxmox_nodes", Value: float64(details.Summary.Nodes), Unit: "count"},
		{Name: "proxmox_guests", Value: float64(details.Summary.Guests), Unit: "count"},
		{Name: "proxmox_qemu_guests", Value: float64(details.Summary.QEMU), Unit: "count"},
		{Name: "proxmox_lxc_guests", Value: float64(details.Summary.LXC), Unit: "count"},
		{Name: "proxmox_storage", Value: float64(details.Summary.Storage), Unit: "count"},
		{Name: "proxmox_network_interfaces", Value: float64(details.Summary.NetworkInterfaces), Unit: "count"},
		{Name: "proxmox_disks", Value: float64(details.Summary.Disks), Unit: "count"},
		{Name: "proxmox_ceph_enabled_nodes", Value: float64(details.Summary.CephEnabledNodes), Unit: "count"},
		{Name: "proxmox_ceph_warn_nodes", Value: float64(details.ResourceSummary.CephWarnNodes), Unit: "count", Thresholds: sdk.Thresholds(1, 1)},
		{Name: "proxmox_ceph_error_nodes", Value: float64(details.ResourceSummary.CephErrorNodes), Unit: "count", Thresholds: sdk.Thresholds(1, 1)},
		{Name: "proxmox_node_cpu_ratio_max", Value: details.ResourceSummary.MaxNodeCPURatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
		{Name: "proxmox_node_mem_ratio_max", Value: details.ResourceSummary.MaxNodeMemRatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
		{Name: "proxmox_node_io_wait_ratio_max", Value: details.ResourceSummary.MaxNodeIOWaitRatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.20, 0.40)},
		{Name: "proxmox_node_storage_ratio_max", Value: details.ResourceSummary.MaxNodeStorageRatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
		{Name: "proxmox_guest_cpu_ratio_max", Value: details.ResourceSummary.MaxGuestCPURatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
		{Name: "proxmox_guest_mem_ratio_max", Value: details.ResourceSummary.MaxGuestMemRatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
		{Name: "proxmox_guest_disk_ratio_max", Value: details.ResourceSummary.MaxGuestDiskRatio, Unit: "ratio", Thresholds: sdk.Thresholds(0.80, 0.90)},
	}
}

type metricBatch struct {
	Resource          metricResource
	IngestIdentity    metricIngestIdentity
	EmittedAtUnixNano uint64
	Samples           []metricTelemetrySample
	ObservedAt        uint64
}

type metricResource struct {
	ServiceName string
	ServiceType string
	Attributes  []metricStringMapEntry
}

type metricIngestIdentity struct {
	Source       string
	ProducerID   string
	ProducerKind string
}

type metricStringMapEntry struct {
	Key   string
	Value string
}

func encodeMetricBatch(batch metricBatch) []byte {
	var out []byte
	out = appendString(out, 1, metricEnvelopeSchemaVersion)
	out = appendMessage(out, 2, encodeMetricResource(batch.Resource))
	out = appendMessage(out, 3, encodeMetricIngestIdentity(batch.IngestIdentity))
	out = appendUint64(out, 6, batch.EmittedAtUnixNano)
	for _, sample := range batch.Samples {
		out = appendMessage(out, 20, encodeMetric(sample, batch.ObservedAt))
	}
	return out
}

func encodeMetricResource(resource metricResource) []byte {
	var out []byte
	out = appendString(out, 4, resource.ServiceName)
	out = appendString(out, 5, resource.ServiceType)
	for _, attr := range resource.Attributes {
		out = appendMessage(out, 20, encodeMetricStringMapEntry(attr))
	}
	return out
}

func encodeMetricIngestIdentity(identity metricIngestIdentity) []byte {
	var out []byte
	out = appendString(out, 1, identity.Source)
	out = appendString(out, 2, metricEnvelopeSchemaVersion)
	out = appendString(out, 3, identity.ProducerID)
	out = appendString(out, 4, identity.ProducerKind)
	return out
}

func encodeMetric(sample metricTelemetrySample, observedAt uint64) []byte {
	var out []byte
	out = appendString(out, 1, sample.Name)
	out = appendString(out, 2, "plugin")
	out = appendInt32(out, 3, 1)
	out = appendString(out, 6, sample.Unit)
	out = appendMessage(out, 20, encodeMetricPoint(sample.Value, observedAt))
	for _, threshold := range metricThresholds(sample.Thresholds) {
		out = appendMessage(out, 32, encodeMetricStringMapEntry(threshold))
	}
	return out
}

func metricThresholds(thresholds *sdk.ThresholdSpec) []metricStringMapEntry {
	if thresholds == nil {
		return nil
	}

	out := make([]metricStringMapEntry, 0, 4)
	if thresholds.Warn != nil {
		out = append(out, metricStringMapEntry{Key: "warn", Value: strconv.FormatFloat(*thresholds.Warn, 'f', -1, 64)})
	}
	if thresholds.Crit != nil {
		out = append(out, metricStringMapEntry{Key: "crit", Value: strconv.FormatFloat(*thresholds.Crit, 'f', -1, 64)})
	}
	if thresholds.Min != nil {
		out = append(out, metricStringMapEntry{Key: "min", Value: strconv.FormatFloat(*thresholds.Min, 'f', -1, 64)})
	}
	if thresholds.Max != nil {
		out = append(out, metricStringMapEntry{Key: "max", Value: strconv.FormatFloat(*thresholds.Max, 'f', -1, 64)})
	}
	return out
}

func encodeMetricPoint(value float64, observedAt uint64) []byte {
	var out []byte
	out = appendDouble(out, 1, value)
	out = appendString(out, 2, strconv.FormatFloat(value, 'f', -1, 64))
	out = appendInt32(out, 3, 1)
	out = appendUint64(out, 4, observedAt)
	return out
}

func encodeMetricStringMapEntry(entry metricStringMapEntry) []byte {
	var out []byte
	out = appendString(out, 1, entry.Key)
	out = appendString(out, 2, entry.Value)
	return out
}

func appendString(out []byte, field int, value string) []byte {
	if value == "" {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendMessage(out []byte, field int, value []byte) []byte {
	if len(value) == 0 {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendInt32(out []byte, field int, value int32) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, uint64(value))
}

func appendUint64(out []byte, field int, value uint64) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, value)
}

func appendDouble(out []byte, field int, value float64) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 1)
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], math.Float64bits(value))
	return append(out, buf[:]...)
}

func appendTag(out []byte, field int, wireType int) []byte {
	return binary.AppendUvarint(out, uint64(field<<3|wireType))
}
