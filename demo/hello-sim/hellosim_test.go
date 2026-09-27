package main

import (
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/carverauto/serviceradar/demo/pluginkit"
	"github.com/carverauto/serviceradar/demo/simkit"
	"github.com/carverauto/serviceradar/demo/simkit/guard"
	"github.com/carverauto/serviceradar/demo/tools/rulecheck"
)

var day0 = time.Date(2026, 9, 26, 0, 0, 0, 0, time.UTC)

// runDay drives the plugin exactly as the agent would: one run per interval,
// each backfilling its own window, for a simulated day.
func runDay(t *testing.T) []pluginkit.Output {
	t.Helper()
	cfg := Config{IntervalSeconds: 60}
	var outs []pluginkit.Output
	for now := day0.Add(time.Minute); now.Before(day0.Add(24 * time.Hour)); now = now.Add(time.Minute) {
		_, out, err := collect(cfg, now)
		if err != nil {
			t.Fatalf("run at %s: %v", now, err)
		}
		outs = append(outs, out)
	}
	return outs
}

func TestADayOfRunsIsGuardCleanAndWithinCaps(t *testing.T) {
	var devices, records int
	for _, out := range runDay(t) {
		for _, b := range out.Telemetry {
			if len(b.Records) > simkit.MaxTelemetryBatch {
				t.Fatalf("telemetry batch of %d records exceeds the agent cap", len(b.Records))
			}
			records += len(b.Records)
		}
		r := sdk.NewResult()
		out.Apply(r)
		vs, err := guard.Check(r)
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range vs {
			t.Errorf("guard: %s", v)
		}
		if out.Discovery != nil {
			devices += len(out.Discovery.Devices)
		}
	}
	if records == 0 {
		t.Fatal("a day of runs emitted no metric records")
	}
	// Inventory rides a 15-minute cadence. The runs cover (00:00, 23:59], which
	// holds the 95 boundaries 00:15 ... 23:45; each emits the 3 sensors once.
	if devices != 95*3 {
		t.Fatalf("inventory records over a day = %d, want %d", devices, 95*3)
	}
}

func TestFaultsOpenAndResolveTheShippedAlertRule(t *testing.T) {
	rules, err := rulecheck.Load(manifestPath(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 1 || rules[0].Signal != "event" {
		t.Fatalf("manifest alert_rules = %+v", rules)
	}
	rule := rules[0]

	open := map[string]string{} // fault id -> group key
	var opened, resolved int
	for _, out := range runDay(t) {
		for _, ev := range out.Events {
			e := rulecheck.Event{LogName: ev.LogName, Attributes: ev.Unmapped}
			fault, _ := ev.Unmapped[pluginkit.AttrFaultID].(string)
			key, ok := rule.GroupKey(e)
			if !ok {
				t.Fatalf("event %s lacks the rule's group_by keys", ev.ID)
			}
			switch {
			case rule.Opens(e) && !rule.Resolves(e):
				opened++
				open[fault] = key
			case rule.Resolves(e) && !rule.Opens(e):
				resolved++
				if open[fault] != key {
					t.Fatalf("resolving event %s groups as %q, its opening as %q", ev.ID, key, open[fault])
				}
				delete(open, fault)
			default:
				t.Fatalf("event %s neither cleanly opens nor resolves the rule: %+v", ev.ID, ev.Unmapped)
			}
		}
	}
	if opened < 24 {
		t.Fatalf("only %d faults opened in a day; the pack schedules one about every 8 minutes", opened)
	}
	// A fault still active at the end of the day has not resolved yet.
	if opened-resolved > 1 || len(open) > 1 {
		t.Fatalf("opened %d, resolved %d, still open %v", opened, resolved, open)
	}
}

func TestRunIsDeterministic(t *testing.T) {
	now := day0.Add(90 * time.Minute)
	_, a, errA := collect(Config{}, now)
	_, b, errB := collect(Config{}, now)
	if errA != nil || errB != nil {
		t.Fatal(errA, errB)
	}
	if len(a.Events) != len(b.Events) || len(a.Telemetry) != len(b.Telemetry) {
		t.Fatal("two runs at the same instant differ")
	}
	for i := range a.Telemetry {
		for j := range a.Telemetry[i].Records {
			if a.Telemetry[i].Records[j].Payload != b.Telemetry[i].Records[j].Payload {
				t.Fatalf("record %d/%d payload differs between identical runs", i, j)
			}
		}
	}
}

func TestTelemetryIsAttributedToThePlugin(t *testing.T) {
	_, out, err := collect(Config{}, day0.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Telemetry) == 0 || len(out.Telemetry[0].Records) == 0 {
		t.Fatal("no telemetry")
	}
	if out.Telemetry[0].Source.SourceInstance != PluginID {
		t.Fatalf("telemetry source = %+v", out.Telemetry[0].Source)
	}
}

func manifestPath(t *testing.T) string {
	t.Helper()
	for _, p := range []string{"plugin.yaml", "demo/hello-sim/plugin.yaml"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	t.Fatal("plugin.yaml not found in runfiles")
	return ""
}
