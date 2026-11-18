package main

import (
	"sort"
	"strconv"
	"time"
)

type metricSample struct {
	Name  string
	Unit  string
	Value float64
	Tags  map[string]string
}

type kvEntry struct {
	Key   string
	Value string
}

func sortedMapEntries(m map[string]string) []kvEntry {
	if len(m) == 0 {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		if k != "" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	out := make([]kvEntry, 0, len(keys))
	for _, k := range keys {
		out = append(out, kvEntry{Key: k, Value: m[k]})
	}
	return out
}

func baseMetricTags(cfg RunnerConfig, target TargetSpec, nodeID, nodeType string) map[string]string {
	tags := map[string]string{
		"check_id":   cfg.CheckID,
		"check_slug": cfg.Slug,
		"target_key": target.TargetKey,
		"node_id":    nodeID,
		"node_type":  nodeType,
	}
	if target.DeviceUID != "" {
		tags["device_uid"] = target.DeviceUID
	}
	if target.ServiceTargetID != "" {
		tags["service_target_id"] = target.ServiceTargetID
	}
	return tags
}

func cloneTagsWith(base map[string]string, extraKey, extraVal string) map[string]string {
	out := make(map[string]string, len(base)+1)
	for k, v := range base {
		out[k] = v
	}
	if extraKey != "" {
		out[extraKey] = extraVal
	}
	return out
}

func appendHTTPTraceMetrics(samples []metricSample, prefix string, tags map[string]string, trace *hostHTTPTrace) []metricSample {
	if trace == nil {
		return samples
	}
	if trace.DNSMS > 0 {
		samples = append(samples, metricSample{Name: prefix + ".dns_ms", Unit: "ms", Value: trace.DNSMS, Tags: tags})
	}
	if trace.TCPMS > 0 {
		samples = append(samples, metricSample{Name: prefix + ".tcp_ms", Unit: "ms", Value: trace.TCPMS, Tags: tags})
	}
	if trace.TLSMS > 0 {
		samples = append(samples, metricSample{Name: prefix + ".tls_ms", Unit: "ms", Value: trace.TLSMS, Tags: tags})
	}
	if trace.TTFBMS > 0 {
		samples = append(samples, metricSample{Name: prefix + ".ttfb_ms", Unit: "ms", Value: trace.TTFBMS, Tags: tags})
	}
	if trace.TransferMS > 0 {
		samples = append(samples, metricSample{Name: prefix + ".transfer_ms", Unit: "ms", Value: trace.TransferMS, Tags: tags})
	}
	return samples
}

func durationMS(d time.Duration) float64 {
	if d <= 0 {
		return 0
	}
	ms := float64(d.Microseconds()) / 1000.0
	return float64(int64(ms*100+0.5)) / 100.0
}

func tryDecodeStatusBody(payload []byte, duration time.Duration) (*hostHTTPResp, bool, error) {
	lineEnd := -1
	for i, ch := range payload {
		if ch == '\n' {
			lineEnd = i
			break
		}
		if ch < '0' || ch > '9' {
			return nil, false, nil
		}
	}
	if lineEnd <= 0 {
		return nil, false, nil
	}
	status, err := strconv.Atoi(string(payload[:lineEnd]))
	if err != nil {
		return nil, true, err
	}
	return &hostHTTPResp{
		Status:   status,
		Body:     append([]byte(nil), payload[lineEnd+1:]...),
		Duration: duration,
	}, true, nil
}

func itoa(v int) string {
	return strconv.Itoa(v)
}
