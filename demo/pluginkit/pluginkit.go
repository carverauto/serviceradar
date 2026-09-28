// Package pluginkit maps a simkit.Batch onto ServiceRadar SDK calls, so every
// demo plugin emits product contracts the same way: inventory as device
// discovery in the result, faults as OCSF events in the result, and metrics as
// metric batches through emit_telemetry (the JetStream-first path).
//
// Build is pure and runs natively in tests; Emit and Run touch the host.
package pluginkit

import (
	"fmt"
	"sort"
	"strconv"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/carverauto/serviceradar/demo/simkit"
)

// DefaultLogName is the OCSF log_name demo fault events carry. Alert rules
// match on it with subject_prefix.
const DefaultLogName = "demo.fault"

// Attribute keys set on every fault event (OCSF unmapped). Alert rules match
// on these with attribute_equals and group on them with group_by.
const (
	AttrAssetID    = "asset_id"
	AttrFaultState = "demo.fault.state"
	AttrFaultKind  = "demo.fault.kind"
	AttrFaultID    = "demo.fault.id"

	FaultStateOpen     = "open"
	FaultStateResolved = "resolved"
)

// Metric types understood by the platform.
const (
	MetricTypeGauge   = "gauge"
	MetricTypeCounter = "counter"
)

// MetricSpec describes how one metric name is reported.
type MetricSpec struct {
	Type string
	Unit string
}

// Options configure Build.
type Options struct {
	// Source identifies the producer: the device discovery source and the
	// metric ingest source. Use the plugin id.
	Source string
	// LogName overrides DefaultLogName for fault events.
	LogName string
	// Specs maps metric names to their type and unit. Unlisted metrics are
	// gauges with the unit the Metric carries.
	Specs map[string]MetricSpec
	// ResourceFor returns the metric resource for an asset, typically its
	// target IP so the platform can attach the series to the device.
	ResourceFor func(assetID string) sdk.MetricResource
	// MaxRecords caps records per telemetry batch; defaults to the agent cap.
	MaxRecords int
}

// Output is what one run submits.
type Output struct {
	Discovery *sdk.DeviceDiscovery
	Events    []sdk.OCSFEvent
	Telemetry []sdk.TelemetryBatch
	// ActiveFaults is the latest demo.fault.active value in the batch.
	ActiveFaults int
}

// Build maps a batch onto SDK payloads without calling the host.
func Build(b simkit.Batch, opts Options) (Output, error) {
	if opts.Source == "" {
		return Output{}, fmt.Errorf("pluginkit: Options.Source is required")
	}
	out := Output{}
	if len(b.Devices) > 0 {
		out.Discovery = sdk.NewDeviceDiscovery(opts.Source)
		for _, d := range b.Devices {
			out.Discovery.AddDevice(discoveredDevice(d))
		}
	}
	for _, ev := range b.Events {
		out.Events = append(out.Events, faultEvent(ev, opts))
	}
	records, active := metricRecords(b.Metrics, opts)
	out.ActiveFaults = active
	max := opts.MaxRecords
	if max <= 0 {
		max = simkit.MaxTelemetryBatch
	}
	for i := 0; i < len(records); i += max {
		end := i + max
		if end > len(records) {
			end = len(records)
		}
		out.Telemetry = append(out.Telemetry, sdk.TelemetryBatch{
			Source:  sdk.TelemetrySource{SourceType: "plugin", SourceInstance: opts.Source},
			Records: records[i:end],
		})
	}
	return out, nil
}

// Apply adds the inventory and events to a result.
func (o Output) Apply(r *sdk.Result) {
	if o.Discovery != nil {
		r.AddDeviceDiscovery(*o.Discovery)
	}
	for _, ev := range o.Events {
		r.AddOCSFEvent(ev)
	}
}

// Emit sends every telemetry batch to the host.
func (o Output) Emit() error {
	for i, batch := range o.Telemetry {
		if err := sdk.EmitTelemetry(batch); err != nil {
			return fmt.Errorf("emit telemetry batch %d/%d: %w", i+1, len(o.Telemetry), err)
		}
	}
	return nil
}

// Run collects one run from a source and normalizer, emits its telemetry and
// returns the result to submit.
func Run(src simkit.Source, n simkit.Normalizer, ctx simkit.ObserveContext, opts Options) (*sdk.Result, error) {
	batch, err := simkit.Collect(src, n, ctx)
	if err != nil {
		return nil, err
	}
	out, err := Build(batch, opts)
	if err != nil {
		return nil, err
	}
	if err := out.Emit(); err != nil {
		return nil, err
	}
	return out.Result(batch), nil
}

// Result builds the plugin result for a batch: warning while a fault is
// active, OK otherwise.
func (o Output) Result(b simkit.Batch) *sdk.Result {
	summary := fmt.Sprintf("%d devices, %d metrics, %d events, %d active faults",
		len(b.Devices), len(b.Metrics), len(b.Events), o.ActiveFaults)
	var r *sdk.Result
	if o.ActiveFaults > 0 {
		r = sdk.Warning(summary)
	} else {
		r = sdk.Ok(summary)
	}
	o.Apply(r)
	return r
}

func discoveredDevice(d simkit.Device) sdk.DiscoveredDevice {
	labels := map[string]string{AttrAssetID: d.AssetID}
	for k, v := range d.Labels {
		labels[k] = v
	}
	out := sdk.DiscoveredDevice{
		Hostname:   d.Hostname,
		IP:         d.IP,
		MAC:        d.MAC,
		Serial:     d.Serial,
		VendorName: d.Vendor,
		Model:      d.Model,
		Type:       d.Kind,
		Labels:     labels,
	}
	if d.Lat != nil && d.Lon != nil {
		out.Location = &sdk.DeviceLocation{SiteCode: d.Site, SiteName: d.Site, Latitude: *d.Lat, Longitude: *d.Lon}
	} else if d.Site != "" {
		out.Location = &sdk.DeviceLocation{SiteCode: d.Site, SiteName: d.Site}
	}
	return out
}

func faultEvent(ev simkit.Event, opts Options) sdk.OCSFEvent {
	state := FaultStateResolved
	severity := sdk.SeverityInfo
	message := ev.Title + " resolved on " + ev.AssetID
	if ev.Opening {
		state = FaultStateOpen
		severity = openingSeverity(ev.Severity)
		message = ev.Title + " on " + ev.AssetID
	}
	out := sdk.NewOCSFEventLogActivity(message, severity)
	out.ID = ev.ID
	out.Time = ev.Time.UTC()
	out.LogName = opts.LogName
	if out.LogName == "" {
		out.LogName = DefaultLogName
	}
	out.LogProvider = opts.Source
	out.Device = map[string]any{"name": ev.AssetID}
	attrs := map[string]any{
		AttrAssetID:    ev.AssetID,
		AttrFaultState: state,
		AttrFaultKind:  ev.Kind,
		AttrFaultID:    ev.FaultID,
	}
	for k, v := range ev.Labels {
		attrs[k] = v
	}
	out.Unmapped = attrs
	return out
}

func openingSeverity(s string) sdk.Severity {
	switch s {
	case "critical":
		return sdk.SeverityCritical
	case "high":
		return sdk.SeverityError
	case "low", "info":
		return sdk.SeverityInfo
	default:
		return sdk.SeverityWarning
	}
}

type seriesKey struct{ asset, name string }

func metricRecords(ms []simkit.Metric, opts Options) ([]sdk.TelemetryRecord, int) {
	series := map[seriesKey][]simkit.Metric{}
	var keys []seriesKey
	active := 0
	var activeAt int64
	for _, m := range ms {
		k := seriesKey{m.AssetID, m.Name}
		if _, ok := series[k]; !ok {
			keys = append(keys, k)
		}
		series[k] = append(series[k], m)
		if m.Name == simkit.MetricFaultActive && m.Time.UnixNano() >= activeAt {
			activeAt = m.Time.UnixNano()
			active = int(m.Value)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].asset != keys[j].asset {
			return keys[i].asset < keys[j].asset
		}
		return keys[i].name < keys[j].name
	})
	records := make([]sdk.TelemetryRecord, 0, len(keys))
	for _, k := range keys {
		points := series[k]
		sort.SliceStable(points, func(i, j int) bool { return points[i].Time.Before(points[j].Time) })
		records = append(records, metricRecord(k, points, opts))
	}
	return records, active
}

func metricRecord(k seriesKey, points []simkit.Metric, opts Options) sdk.TelemetryRecord {
	spec, ok := opts.Specs[k.name]
	if !ok {
		spec = MetricSpec{Type: MetricTypeGauge, Unit: points[0].Unit}
	}
	metric := sdk.Metric{
		Name:       k.name,
		MetricType: spec.Type,
		Kind:       sdk.MetricKindGauge,
		Unit:       spec.Unit,
	}
	if spec.Type == MetricTypeCounter {
		metric.Kind = sdk.MetricKindSum
		metric.Temporality = sdk.MetricTemporalityCumulative
		metric.IsMonotonic = true
	}
	if k.asset != "" {
		metric.Tags = append(metric.Tags, sdk.MetricStringMapEntry{Key: AttrAssetID, Value: k.asset})
	}
	labels := points[len(points)-1].Labels
	labelKeys := make([]string, 0, len(labels))
	for key := range labels {
		labelKeys = append(labelKeys, key)
	}
	sort.Strings(labelKeys)
	for _, key := range labelKeys {
		metric.Tags = append(metric.Tags, sdk.MetricStringMapEntry{Key: key, Value: labels[key]})
	}
	for _, p := range points {
		metric.Points = append(metric.Points, sdk.MetricPoint{
			Value:              p.Value,
			RawValue:           strconv.FormatFloat(p.Value, 'g', -1, 64),
			RawValueType:       sdk.MetricValueTypeDouble,
			ObservedAtUnixNano: uint64(p.Time.UnixNano()),
		})
	}

	resource := sdk.MetricResource{}
	if opts.ResourceFor != nil && k.asset != "" {
		resource = opts.ResourceFor(k.asset)
	}
	batch := sdk.MetricBatch{
		SchemaVersion: sdk.MetricEnvelopeSchemaVersion,
		Resource:      resource,
		IngestIdentity: sdk.MetricIngestIdentity{
			Source:       opts.Source,
			ProducerID:   opts.Source,
			ProducerKind: "plugin",
		},
		Metrics: []sdk.Metric{metric},
		// Stamp the batch with its newest sample rather than the wall clock
		// (the SDK's default), so a run's payload is a pure function of the
		// simulated state and a repeated run re-sends identical bytes.
		EmittedAtUnixNano: uint64(points[len(points)-1].Time.UnixNano()),
	}
	eventID := opts.Source + "/" + k.asset + "/" + k.name + "/" + strconv.FormatInt(points[len(points)-1].Time.Unix(), 10)
	record := sdk.NewServiceRadarMetricTelemetryRecordFromBatch(eventID, batch)
	last := points[len(points)-1].Time.UnixNano()
	record.EventTimeUnixNano = last
	return record
}
