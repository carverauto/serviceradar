package main

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func defaultConfig() Config {
	return Config{TimeoutMS: defaultTimeoutMS}
}

func newPluginResult(status sdk.Status, summary string) *pluginResult {
	if status == "" {
		status = sdk.StatusUnknown
	}
	if strings.TrimSpace(summary) == "" {
		summary = string(status)
	}

	return &pluginResult{
		Status:        status,
		Summary:       summary,
		SchemaVersion: 1,
		ObservedAt:    time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func (r *pluginResult) AddMetric(name string, value float64, unit string, thresholds *sdk.ThresholdSpec) {
	if r == nil || strings.TrimSpace(name) == "" {
		return
	}

	metric := pluginMetric{Name: name, Value: value, Unit: unit}
	if thresholds != nil {
		metric.Warn = thresholds.Warn
		metric.Crit = thresholds.Crit
		metric.Min = thresholds.Min
		metric.Max = thresholds.Max
	}
	r.Metrics = append(r.Metrics, metric)
}

func (r *pluginResult) AddLabel(key, value string) {
	if r == nil || strings.TrimSpace(key) == "" {
		return
	}
	if r.Labels == nil {
		r.Labels = map[string]string{}
	}
	r.Labels[key] = value
}

func submitPluginResult(result *pluginResult) error {
	if result == nil {
		result = newPluginResult(sdk.StatusUnknown, "")
	}
	if result.SchemaVersion == 0 {
		result.SchemaVersion = 1
	}
	if result.ObservedAt == "" {
		result.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}

	return sdk.SubmitResult(result.JSON())
}

func (r *pluginResult) JSON() []byte {
	var b strings.Builder
	b.WriteString(`{"status":`)
	b.WriteString(strconv.Quote(string(r.Status)))
	b.WriteString(`,"summary":`)
	b.WriteString(strconv.Quote(r.Summary))
	if r.Details != "" {
		b.WriteString(`,"details":`)
		b.WriteString(strconv.Quote(r.Details))
	}
	if len(r.Metrics) > 0 {
		b.WriteString(`,"metrics":[`)
		for i, metric := range r.Metrics {
			if i > 0 {
				b.WriteByte(',')
			}
			appendMetricJSON(&b, metric)
		}
		b.WriteByte(']')
	}
	if len(r.Labels) > 0 {
		b.WriteString(`,"labels":{`)
		keys := make([]string, 0, len(r.Labels))
		for key := range r.Labels {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.Quote(key))
			b.WriteByte(':')
			b.WriteString(strconv.Quote(r.Labels[key]))
		}
		b.WriteByte('}')
	}
	if r.ObservedAt != "" {
		b.WriteString(`,"observed_at":`)
		b.WriteString(strconv.Quote(r.ObservedAt))
	}
	if r.SchemaVersion > 0 {
		b.WriteString(`,"schema_version":`)
		b.WriteString(strconv.Itoa(r.SchemaVersion))
	}
	b.WriteByte('}')

	return []byte(b.String())
}

func appendMetricJSON(b *strings.Builder, metric pluginMetric) {
	b.WriteString(`{"name":`)
	b.WriteString(strconv.Quote(metric.Name))
	b.WriteString(`,"value":`)
	b.WriteString(strconv.FormatFloat(metric.Value, 'f', -1, 64))
	if metric.Unit != "" {
		b.WriteString(`,"unit":`)
		b.WriteString(strconv.Quote(metric.Unit))
	}
	appendOptionalFloat(b, "warn", metric.Warn)
	appendOptionalFloat(b, "crit", metric.Crit)
	appendOptionalFloat(b, "min", metric.Min)
	appendOptionalFloat(b, "max", metric.Max)
	b.WriteByte('}')
}

func appendOptionalFloat(b *strings.Builder, key string, value *float64) {
	if value == nil {
		return
	}
	b.WriteByte(',')
	b.WriteString(strconv.Quote(key))
	b.WriteByte(':')
	b.WriteString(strconv.FormatFloat(*value, 'f', -1, 64))
}
