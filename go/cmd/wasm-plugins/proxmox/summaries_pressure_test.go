package main

import (
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestClassifyPressureLevelBands(t *testing.T) {
	cases := []struct {
		name       string
		value      float64
		warn, crit float64
		want       pressureLevel
	}{
		{"below warn", 0.79, ratioWarnThreshold, ratioCritThreshold, levelOK},
		{"at warn", 0.80, ratioWarnThreshold, ratioCritThreshold, levelWarning},
		{"mid warn", 0.85, ratioWarnThreshold, ratioCritThreshold, levelWarning},
		{"just below crit", 0.899, ratioWarnThreshold, ratioCritThreshold, levelWarning},
		{"at crit", 0.90, ratioWarnThreshold, ratioCritThreshold, levelCritical},
		{"above crit", 0.97, ratioWarnThreshold, ratioCritThreshold, levelCritical},
		{"io wait below warn", 0.19, ioWaitWarnThreshold, ioWaitCritThreshold, levelOK},
		{"io wait warn", 0.20, ioWaitWarnThreshold, ioWaitCritThreshold, levelWarning},
		{"io wait crit", 0.40, ioWaitWarnThreshold, ioWaitCritThreshold, levelCritical},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyPressureLevel(tc.value, tc.warn, tc.crit); got != tc.want {
				t.Fatalf("classifyPressureLevel(%v) = %v, want %v", tc.value, got, tc.want)
			}
		})
	}
}

// TestEmitRatioEventCarriesLevelNotPercentage proves the plugin now emits one
// stable event per level (with the level, ratio and thresholds in unmapped)
// instead of a distinct percentage-bearing message every tick. A steady/rising
// value inside the same band produces byte-identical (condition_key, level)
// identities so the host can collapse the per-cycle repeats.
func TestEmitRatioEventCarriesLevelNotPercentage(t *testing.T) {
	// Two different percentages inside the SAME critical band.
	for _, value := range []float64{0.91, 0.95} {
		result := newPluginResult(sdk.StatusWarning, "resource pressure")
		emitRatioEvent(result, "guest_memory", "cluster:vm:100", value)

		if len(result.TelemetryEvents) != 1 {
			t.Fatalf("value %v: expected 1 event, got %d", value, len(result.TelemetryEvents))
		}
		event := result.TelemetryEvents[0]

		if event.SeverityID != 5 {
			t.Fatalf("value %v: severity_id = %d, want 5 (critical)", value, event.SeverityID)
		}
		if event.Message != "Proxmox guest memory bottleneck (critical)" {
			t.Fatalf("value %v: message = %q (must not embed the percentage)", value, event.Message)
		}
		if got := event.Unmapped["level"]; got != "critical" {
			t.Fatalf("value %v: unmapped.level = %v, want critical", value, got)
		}
		if got := event.Unmapped["condition_key"]; got != "proxmox:guest_memory:cluster:vm:100" {
			t.Fatalf("value %v: unmapped.condition_key = %v", value, got)
		}
		if got, ok := event.Unmapped["ratio"].(float64); !ok || got != value {
			t.Fatalf("value %v: unmapped.ratio = %v, want the raw ratio", value, event.Unmapped["ratio"])
		}
		if got, ok := event.Unmapped["crit"].(float64); !ok || got != ratioCritThreshold {
			t.Fatalf("value %v: unmapped.crit = %v, want %v", value, event.Unmapped["crit"], ratioCritThreshold)
		}
	}
}

func TestEmitPressureEventWarningAndOK(t *testing.T) {
	// Warning band.
	warnResult := newPluginResult(sdk.StatusWarning, "")
	emitRatioEvent(warnResult, "node_cpu", "pve-a", 0.83)
	if len(warnResult.TelemetryEvents) != 1 {
		t.Fatalf("expected 1 warning event, got %d", len(warnResult.TelemetryEvents))
	}
	if warnResult.TelemetryEvents[0].SeverityID != 3 {
		t.Fatalf("severity_id = %d, want 3 (warning)", warnResult.TelemetryEvents[0].SeverityID)
	}
	if warnResult.TelemetryEvents[0].Message != "Proxmox node cpu pressure (warning)" {
		t.Fatalf("message = %q", warnResult.TelemetryEvents[0].Message)
	}

	// OK band emits nothing (no per-cycle spam for healthy resources).
	okResult := newPluginResult(sdk.StatusOK, "")
	emitRatioEvent(okResult, "node_cpu", "pve-a", 0.50)
	if len(okResult.TelemetryEvents) != 0 {
		t.Fatalf("expected no event for an OK resource, got %d", len(okResult.TelemetryEvents))
	}
}
