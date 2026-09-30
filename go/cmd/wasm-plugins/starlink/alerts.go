package main

import (
	"net/http"
	"sort"
	"strings"
	"unicode"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// alertSeverity is ServiceRadar's classification; the vendor publishes none.
// Names not listed default to warning so a new vendor alert is visible
// without being paged as critical.
var alertSeverity = map[string]sdk.Severity{
	"thermal_shutdown":          sdk.SeverityCritical,
	"actuator_motor_stuck":      sdk.SeverityCritical,
	"mast_not_vertical":         sdk.SeverityWarning,
	"unable_to_align":           sdk.SeverityWarning,
	"high_time_obstruction":     sdk.SeverityWarning,
	"psu_otp_throttling":        sdk.SeverityWarning,
	"ethernet_slow_link10":      sdk.SeverityWarning,
	"ethernet_slow_link100":     sdk.SeverityWarning,
	"data_overage_rate_limited": sdk.SeverityWarning,
	"pop_change":                sdk.SeverityInfo,
	// The vendor currently reports this one unreliably; it is surfaced as
	// information only.
	"software_update_reboot_pending": sdk.SeverityInfo,
	"sandbox_disabled":               sdk.SeverityWarning,
	"offline_networks_disabled":      sdk.SeverityWarning,
	"only_overflight_blocked":        sdk.SeverityInfo,
}

func severityFor(name string) sdk.Severity {
	if s, ok := alertSeverity[name]; ok {
		return s
	}
	if strings.HasPrefix(name, "disabled_") {
		// Every disabled_* alert means the terminal has no service.
		return sdk.SeverityCritical
	}
	return sdk.SeverityWarning
}

// conditionLevel maps severity to the agent debounce's discrete levels.
func conditionLevel(s sdk.Severity) string {
	if s == sdk.SeverityCritical {
		return "critical"
	}
	return "warning"
}

type deviceAlerts struct {
	DeviceRef string
	Kind      string // "user_terminal" or "router"
	Active    []string
}

// alertSnapshot is the set of active alerts across the account. Complete is
// true only when every listing page and every cache query succeeded; only a
// complete snapshot may be used to clear alerts that are no longer reported.
type alertSnapshot struct {
	Devices  []deviceAlerts
	Complete bool
	Errors   []string
}

// collectAlerts walks the terminal listing and queries the telemetry cache for
// each page's terminals and routers. Chunking by listing page keeps every
// cache response small and bounded, whatever the fleet size.
func collectAlerts(c *apiClient) alertSnapshot {
	snap := alertSnapshot{Complete: true}
	var queryErr error

	_, err := c.listPagesBatched("/user-terminals", func(rows []gjson.Result) {
		var terminals, routers []string
		// The cache is queried with IDs exactly as the listing returned
		// them; normalization is only for ServiceRadar's own references.
		for _, row := range rows {
			if raw := trimmed(row, "userTerminalId"); normalizeTerminalID(raw) != "" && jsonSafeID(raw) {
				terminals = append(terminals, raw)
			}
			for _, r := range row.Get("routers").Array() {
				if raw := trimmed(r, "routerId"); normalizeRouterID(raw) != "" && jsonSafeID(raw) {
					routers = append(routers, raw)
				}
			}
		}
		if len(terminals) == 0 && len(routers) == 0 {
			return
		}
		devices, err := queryAlertCache(c, terminals, routers)
		if err != nil {
			queryErr = err
			return
		}
		snap.Devices = append(snap.Devices, devices...)
	})
	for _, e := range []error{err, queryErr} {
		if e != nil {
			snap.Complete = false
			snap.Errors = append(snap.Errors, errorCode(e))
		}
	}
	sort.Slice(snap.Devices, func(i, j int) bool { return snap.Devices[i].DeviceRef < snap.Devices[j].DeviceRef })
	return snap
}

func queryAlertCache(c *apiClient, terminals, routers []string) ([]deviceAlerts, error) {
	body := `{"includeUserTerminals":` + boolJSON(len(terminals) > 0) +
		`,"userTerminalIds":` + stringsJSON(terminals) +
		`,"includeRouters":` + boolJSON(len(routers) > 0) +
		`,"routerIds":` + stringsJSON(routers) + `}`
	content, err := c.call(http.MethodPost, "/telemetry/query", nil, []byte(body), 0)
	if err != nil {
		return nil, err
	}

	var out []deviceAlerts
	content.Get("userTerminals").ForEach(func(key, value gjson.Result) bool {
		if ref := terminalDeviceID(firstNonEmpty(value.Get("userTerminalId").String(), key.String())); ref != "" {
			out = append(out, deviceAlerts{DeviceRef: ref, Kind: "user_terminal", Active: activeAlertFlags(value)})
		}
		return true
	})
	content.Get("routers").ForEach(func(key, value gjson.Result) bool {
		if ref := routerDeviceID(firstNonEmpty(value.Get("routerId").String(), key.String())); ref != "" {
			out = append(out, deviceAlerts{DeviceRef: ref, Kind: "router", Active: activeAlertFlags(value)})
		}
		return true
	})
	return out, nil
}

// activeAlertFlags returns the snake_case names of every alert* field that is
// exactly true. A null flag means the vendor does not know, which is neither
// raised nor cleared.
func activeAlertFlags(record gjson.Result) []string {
	var active []string
	record.ForEach(func(key, value gjson.Result) bool {
		field := key.String()
		if strings.HasPrefix(field, "alert") && len(field) > len("alert") && value.Type == gjson.True {
			active = append(active, snakeCase(strings.TrimPrefix(field, "alert")))
		}
		return true
	})
	sort.Strings(active)
	return active
}

func snakeCase(camel string) string {
	var b strings.Builder
	for i, r := range camel {
		if unicode.IsUpper(r) {
			if i > 0 {
				b.WriteByte('_')
			}
			r = unicode.ToLower(r)
		}
		b.WriteRune(r)
	}
	return b.String()
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}

func boolJSON(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

func stringsJSON(values []string) string {
	if len(values) == 0 {
		return "[]"
	}
	quoted := make([]string, len(values))
	for i, v := range values {
		// Callers pass only IDs accepted by jsonSafeID.
		quoted[i] = `"` + v + `"`
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

// jsonSafeID accepts the vendor ID alphabet (letters, digits, hyphen), which
// needs no JSON escaping; anything else is dropped rather than encoded.
func jsonSafeID(id string) bool {
	for _, r := range id {
		if !(r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') {
			return false
		}
	}
	return id != ""
}
