// Package fixture turns simulator output into dashboard harness frames, so a
// dashboard's offline fixtures come from the same code the plugin runs.
package fixture

import (
	"bytes"
	"encoding/json"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
)

// Frame is one data frame in the shape the dashboard dev harness loads.
type Frame struct {
	ID       string           `json:"id"`
	Query    string           `json:"query"`
	Encoding string           `json:"encoding"`
	Status   string           `json:"status"`
	Limit    int              `json:"limit"`
	Results  []map[string]any `json:"results"`
}

// NewFrame builds a json_rows frame.
func NewFrame(id, query string, limit int, rows []map[string]any) Frame {
	if rows == nil {
		rows = []map[string]any{}
	}
	return Frame{ID: id, Query: query, Encoding: "json_rows", Status: "ok", Limit: limit, Results: rows}
}

// LatestByAsset joins devices with the latest value of each metric per asset,
// one row per device.
func LatestByAsset(devices []simkit.Device, metrics []simkit.Metric) []map[string]any {
	type key struct{ asset, name string }
	latest := map[key]simkit.Metric{}
	for _, m := range metrics {
		k := key{m.AssetID, m.Name}
		if cur, ok := latest[k]; !ok || m.Time.After(cur.Time) {
			latest[k] = m
		}
	}
	rows := make([]map[string]any, 0, len(devices))
	for _, d := range devices {
		row := map[string]any{"asset_id": d.AssetID}
		for k, v := range map[string]string{
			"kind": d.Kind, "name": d.Name, "site": d.Site, "hostname": d.Hostname,
			"ip": d.IP, "mac": d.MAC, "serial": d.Serial, "vendor": d.Vendor, "model": d.Model,
		} {
			if v != "" {
				row[k] = v
			}
		}
		if d.Lat != nil && d.Lon != nil {
			row["lat"], row["lon"] = *d.Lat, *d.Lon
		}
		var seenAt time.Time
		for k, m := range latest {
			if k.asset == d.AssetID {
				row[m.Name] = m.Value
				if m.Time.After(seenAt) {
					seenAt = m.Time
				}
			}
		}
		if !seenAt.IsZero() {
			row["last_seen"] = seenAt.UTC().Format(time.RFC3339)
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i]["asset_id"].(string) < rows[j]["asset_id"].(string) })
	return rows
}

// EventRows renders events newest first.
func EventRows(events []simkit.Event) []map[string]any {
	sorted := append([]simkit.Event(nil), events...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Time.After(sorted[j].Time) })
	rows := make([]map[string]any, 0, len(sorted))
	for _, e := range sorted {
		rows = append(rows, map[string]any{
			"id": e.ID, "asset_id": e.AssetID, "kind": e.Kind, "title": e.Title,
			"severity": e.Severity, "state": map[bool]string{true: "open", false: "resolved"}[e.Opening],
			"fault_id": e.FaultID, "time": e.Time.UTC().Format(time.RFC3339),
		})
	}
	return rows
}

// Marshal renders frames as stable, indented JSON with a trailing newline.
// Map keys are sorted by encoding/json, so output is byte-for-byte stable.
func Marshal(frames []Frame) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(frames); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
