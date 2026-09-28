package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

const syntheticNACBlock = `interface GigabitEthernet1/0/7
 description endpoint port
 switchport mode access
 dot1x pae authenticator
 authentication port-control auto
!`

func mustCheckConfig(t *testing.T, raw string) interfaceCheckConfig {
	t.Helper()
	cfg, err := parseInterfaceCheckConfig(json.RawMessage(raw))
	if err != nil {
		t.Fatalf("parseInterfaceCheckConfig: %v", err)
	}
	return cfg
}

func TestExpandInterfaceName(t *testing.T) {
	cases := map[string]string{
		"gi1/0/7":              "GigabitEthernet1/0/7",
		"Gi1/0/7":              "GigabitEthernet1/0/7",
		"te1/1/1":              "TenGigabitEthernet1/1/1",
		"tw1/0/3":              "TwoGigabitEthernet1/0/3",
		"twe1/0/3":             "TwentyFiveGigE1/0/3",
		"po12":                 "Port-channel12",
		"GigabitEthernet1/0/7": "GigabitEthernet1/0/7",
		"1/1/20":               "1/1/20",
		"1":                    "1",
		"A1":                   "A1",
	}
	for in, want := range cases {
		if got := expandInterfaceName(in, nil); got != want {
			t.Errorf("expandInterfaceName(%q) = %q, want %q", in, got, want)
		}
	}
	if got := expandInterfaceName("mgmt0", map[string]string{"MGMT": "Management"}); got != "Management0" {
		t.Errorf("operator override: got %q", got)
	}
	if got := expandInterfaceName("gi1/0/7", map[string]string{"gi": "Gig"}); got != "Gig1/0/7" {
		t.Errorf("override of a default: got %q", got)
	}
}

func TestResolveAttachmentShapes(t *testing.T) {
	cases := []struct {
		name  string
		item  map[string]any
		field string
		host  string
		port  string
		ok    bool
	}{
		{
			name:  "projected map field",
			item:  map[string]any{"fields": map[string]any{"switch_port_attachment": map[string]any{"switch_hostname": "switch01.example.com", "port": "gi1/0/7"}}},
			field: "switch_port_attachment",
			host:  "switch01.example.com", port: "gi1/0/7", ok: true,
		},
		{
			name:  "map with only raw",
			item:  map[string]any{"switch_port_attachment": map[string]any{"raw": "switch01.example.com:1/1/20"}},
			field: "switch_port_attachment",
			host:  "switch01.example.com", port: "1/1/20", ok: true,
		},
		{
			name:  "metadata string split on last colon",
			item:  map[string]any{"metadata": map[string]any{"armis_access_switch": "switch02.example.com:gi1/0/3"}},
			field: "metadata.armis_access_switch",
			host:  "switch02.example.com", port: "gi1/0/3", ok: true,
		},
		{name: "missing", item: map[string]any{}, field: "switch_port_attachment"},
		{name: "no colon", item: map[string]any{"metadata": map[string]any{"a": "switch01"}}, field: "metadata.a"},
	}
	for _, tc := range cases {
		host, port, ok := resolveAttachment(tc.item, tc.field)
		if host != tc.host || port != tc.port || ok != tc.ok {
			t.Errorf("%s: got (%q, %q, %v), want (%q, %q, %v)", tc.name, host, port, ok, tc.host, tc.port, tc.ok)
		}
	}
}

func TestInterfaceCheckEvaluate(t *testing.T) {
	cfg := mustCheckConfig(t, `{"checks":[
	  {"name":"nac","patterns":["authentication port-control auto","dot1x pae authenticator"]},
	  {"name":"any_desc","match":"any","patterns":["description uplink","description endpoint"]},
	  {"name":"strict_case","case_sensitive":true,"patterns":["DOT1X PAE AUTHENTICATOR"]},
	  {"name":"regex_mode","regex":true,"patterns":["^\\s*switchport mode (access|trunk)$"]}
	]}`)
	want := map[string]bool{"nac": true, "any_desc": true, "strict_case": false, "regex_mode": true}
	for _, check := range cfg.Checks {
		passed, missing := check.evaluate(syntheticNACBlock)
		if passed != want[check.Name] {
			t.Errorf("%s: passed = %v (missing %v), want %v", check.Name, passed, missing, want[check.Name])
		}
	}

	partial := strings.Replace(syntheticNACBlock, " authentication port-control auto\n", "", 1)
	passed, missing := cfg.Checks[0].evaluate(partial)
	if passed || len(missing) != 1 || missing[0] != "authentication port-control auto" {
		t.Fatalf("partial block: passed=%v missing=%v", passed, missing)
	}
}

func TestParseInterfaceCheckConfigRejectsInvalid(t *testing.T) {
	for name, raw := range map[string]string{
		"no checks":         `{"checks":[]}`,
		"bad name":          `{"checks":[{"name":"NAC Check","patterns":["x"]}]}`,
		"name too long":     `{"checks":[{"name":"` + strings.Repeat("a", 45) + `","patterns":["x"]}]}`,
		"empty pattern":     `{"checks":[{"name":"nac","patterns":[" "]}]}`,
		"bad regex":         `{"checks":[{"name":"nac","regex":true,"patterns":["("]}]}`,
		"bad match":         `{"checks":[{"name":"nac","match":"most","patterns":["x"]}]}`,
		"duplicate":         `{"checks":[{"name":"nac","patterns":["x"]},{"name":"nac","patterns":["y"]}]}`,
		"start placeholder": `{"block_start":"interface","checks":[{"name":"nac","patterns":["x"]}]}`,
		"unknown field":     `{"checks":[{"name":"nac","patterns":["x"]}],"surprise":true}`,
	} {
		if _, err := parseInterfaceCheckConfig(json.RawMessage(raw)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	cfg := mustCheckConfig(t, `{"checks":[{"name":"nac","patterns":["x"]}]}`)
	if cfg.AttachmentField != "switch_port_attachment" || cfg.BlockStart != "interface {interface}" || cfg.BlockEnd != "!" {
		t.Fatalf("defaults not applied: %#v", cfg)
	}
}

func TestRunInterfaceChecksAgainstNA(t *testing.T) {
	httpClient := &fakeHTTPDoer{responses: []HTTPResponse{
		{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticNACBlock) + `}`)},
		{Status: 200, Body: []byte(`{}`)},
		{Status: 400, Body: []byte(`{"message":"device not found"}`)},
	}}
	collector := &Collector{HTTP: httpClient, Now: func() time.Time { return time.Unix(1_790_000_000, 0) }, Sleep: sleepWithContext}
	checkCfg := mustCheckConfig(t, `{"checks":[{"name":"nac","patterns":["authentication port-control auto","dot1x pae authenticator"]}]}`)
	attach := func(host, port string) map[string]any {
		return map[string]any{"fields": map[string]any{"switch_port_attachment": map[string]any{"switch_hostname": host, "port": port}}}
	}
	items := []map[string]any{
		mergeItem(map[string]any{"uid": "sr:00000000-0000-4000-8000-000000000001"}, attach("switch01.example.com", "gi1/0/7")),
		// Same switch and port as above: served from the per-run cache.
		mergeItem(map[string]any{"uid": "sr:00000000-0000-4000-8000-000000000002"}, attach("SWITCH01.example.com", "Gi1/0/7")),
		mergeItem(map[string]any{"uid": "sr:00000000-0000-4000-8000-000000000003"}, attach("switch02.example.com", "gi1/0/9")),
		{"uid": "sr:00000000-0000-4000-8000-000000000004"},
		mergeItem(map[string]any{"uid": "sr:00000000-0000-4000-8000-000000000005"}, attach("switch09.example.com", "gi1/0/1")),
	}

	verdicts, err := collector.runInterfaceChecks(context.Background(), mustValidConfig(t), checkCfg, items)
	if err != nil {
		t.Fatalf("runInterfaceChecks: %v", err)
	}
	if len(httpClient.requests) != 3 {
		t.Fatalf("NA requests = %d, want 3 (repeat port cached, missing attachment skipped)", len(httpClient.requests))
	}
	command, params := decodeCommand(t, httpClient.requests[0])
	if command != configletCommand || params["host"] != "switch01.example.com" ||
		params["start"] != "interface GigabitEthernet1/0/7" || params["end"] != "!" {
		t.Fatalf("configlet request = %q %#v", command, params)
	}

	got := map[string]checkVerdict{}
	for _, verdict := range verdicts {
		got[verdict.DeviceUID] = verdict
	}
	expect := map[string][2]string{
		"sr:00000000-0000-4000-8000-000000000001": {checkStatusCompliant, ""},
		"sr:00000000-0000-4000-8000-000000000002": {checkStatusCompliant, ""},
		"sr:00000000-0000-4000-8000-000000000003": {checkStatusNonCompliant, "interface_not_configured"},
		"sr:00000000-0000-4000-8000-000000000004": {checkStatusUnknown, "attachment_missing"},
		"sr:00000000-0000-4000-8000-000000000005": {checkStatusUnknown, "configlet_not_found"},
	}
	for uid, want := range expect {
		if got[uid].Status != want[0] || got[uid].Reason != want[1] {
			t.Errorf("%s: got %s/%s, want %s/%s", uid, got[uid].Status, got[uid].Reason, want[0], want[1])
		}
	}
	if missing := got["sr:00000000-0000-4000-8000-000000000003"].Missing; len(missing) != 2 {
		t.Errorf("unconfigured interface should miss every required pattern: %v", missing)
	}
	if got["sr:00000000-0000-4000-8000-000000000001"].Interface != "GigabitEthernet1/0/7" {
		t.Errorf("interface not expanded: %#v", got["sr:00000000-0000-4000-8000-000000000001"])
	}
}

func TestRunInterfaceChecksAbortsOnAuthFailure(t *testing.T) {
	httpClient := &fakeHTTPDoer{responses: []HTTPResponse{{Status: 401}}}
	collector := &Collector{HTTP: httpClient, Now: time.Now, Sleep: sleepWithContext}
	checkCfg := mustCheckConfig(t, `{"checks":[{"name":"nac","patterns":["x"]}]}`)
	items := []map[string]any{{
		"uid":                    "sr:00000000-0000-4000-8000-000000000001",
		"switch_port_attachment": map[string]any{"switch_hostname": "switch01.example.com", "port": "1"},
	}}
	_, err := collector.runInterfaceChecks(context.Background(), mustValidConfig(t), checkCfg, items)
	if err == nil || !strings.Contains(err.Error(), "opentext_nom_auth_failed") {
		t.Fatalf("err = %v, want the run to fail on NA auth", err)
	}
}

func TestConfigCheckResultCarriesVerdictsNotConfig(t *testing.T) {
	result, err := buildConfigCheckResult([]checkVerdict{{
		DeviceUID: "sr:00000000-0000-4000-8000-000000000001", Check: "nac", Status: checkStatusNonCompliant,
		Switch: "switch01.example.com", Interface: "1", Missing: []string{"aaa port-access authenticator 1"},
	}}, checkCoverage{}, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	var details map[string]any
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatal(err)
	}
	if details["schema"] != configCheckResultSchema {
		t.Fatalf("details = %#v", details)
	}
	if !strings.Contains(result.Summary, "1 non-compliant") {
		t.Fatalf("summary = %q", result.Summary)
	}
}

func TestRunInterfaceChecksMarksTargetsBeyondMaxUnknown(t *testing.T) {
	httpClient := &fakeHTTPDoer{responses: []HTTPResponse{
		{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticNACBlock) + `}`)},
	}}
	collector := &Collector{HTTP: httpClient, Now: func() time.Time { return time.Unix(1_790_000_000, 0) }, Sleep: sleepWithContext}
	checkCfg := mustCheckConfig(t, `{"max_targets":1,"checks":[{"name":"nac","patterns":["authentication port-control auto"]}]}`)
	items := []map[string]any{
		{"uid": "sr:00000000-0000-4000-8000-000000000001", "switch_port_attachment": "switch01.example.com:gi1/0/7"},
		{"uid": "sr:00000000-0000-4000-8000-000000000002", "switch_port_attachment": "switch01.example.com:gi1/0/8"},
	}
	verdicts, err := collector.runInterfaceChecks(context.Background(), mustValidConfig(t), checkCfg, items)
	if err != nil {
		t.Fatal(err)
	}
	if len(httpClient.requests) != 1 || len(verdicts) != 2 {
		t.Fatalf("requests = %d, verdicts = %d, want 1 and 2", len(httpClient.requests), len(verdicts))
	}
	if verdicts[0].Status != checkStatusCompliant {
		t.Errorf("first verdict = %#v", verdicts[0])
	}
	if verdicts[1].DeviceUID != "sr:00000000-0000-4000-8000-000000000002" ||
		verdicts[1].Status != checkStatusUnknown || verdicts[1].Reason != reasonTargetLimitExceeded {
		t.Errorf("target beyond max_targets = %#v", verdicts[1])
	}
}

type advancingDoer struct {
	inner HTTPDoer
	clock *time.Time
	step  time.Duration
}

func (a *advancingDoer) Do(ctx context.Context, request HTTPRequest) (HTTPResponse, error) {
	*a.clock = a.clock.Add(a.step)
	return a.inner.Do(ctx, request)
}

func TestRunInterfaceChecksStopsCallingNAWhenBudgetSpent(t *testing.T) {
	httpClient := &fakeHTTPDoer{responses: []HTTPResponse{
		{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticNACBlock) + `}`)},
		{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticNACBlock) + `}`)},
		{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticNACBlock) + `}`)},
	}}
	clock := time.Unix(1_790_000_000, 0)
	collector := &Collector{
		HTTP:  &advancingDoer{inner: httpClient, clock: &clock, step: 45 * time.Second},
		Now:   func() time.Time { return clock },
		Sleep: sleepWithContext,
	}
	checkCfg := mustCheckConfig(t, `{"run_budget_seconds":60,"checks":[{"name":"nac","patterns":["authentication port-control auto"]}]}`)
	var items []map[string]any
	for i := 1; i <= 4; i++ {
		items = append(items, map[string]any{
			"uid":                    fmt.Sprintf("sr:00000000-0000-4000-8000-00000000000%d", i),
			"switch_port_attachment": fmt.Sprintf("switch01.example.com:gi1/0/%d", i),
		})
	}
	verdicts, err := collector.runInterfaceChecks(context.Background(), mustValidConfig(t), checkCfg, items)
	if err != nil {
		t.Fatal(err)
	}
	if len(httpClient.requests) != 2 {
		t.Fatalf("NA requests = %d, want 2 before the budget is spent", len(httpClient.requests))
	}
	if len(verdicts) != 4 {
		t.Fatalf("verdicts = %d, want one per target", len(verdicts))
	}
	for i, verdict := range verdicts {
		wantSkipped := i >= 2
		if (verdict.Reason == reasonTargetLimitExceeded) != wantSkipped {
			t.Errorf("verdict %d = %#v, skipped want %v", i, verdict, wantSkipped)
		}
		if wantSkipped && verdict.Status != checkStatusUnknown {
			t.Errorf("verdict %d status = %s, want unknown", i, verdict.Status)
		}
	}
}

func TestConfigCheckResultSurfacesPartialCoverage(t *testing.T) {
	const doc = `{"config_check":{"checks":[{"name":"desc","patterns":["x"]}]},
		"action_invocation":{"target_items":{"entity":"devices","total":5,"truncated":true,"items":[{"uid":"sr:00000000-0000-4000-8000-000000000001"},{"uid":"sr:00000000-0000-4000-8000-000000000002"}]}}}`
	run, err := parseConfigCheckRun(rawConfig(t, doc))
	if err != nil {
		t.Fatal(err)
	}
	verdicts := []checkVerdict{
		{DeviceUID: "sr:00000000-0000-4000-8000-000000000001", Check: "desc", Status: checkStatusCompliant},
		{DeviceUID: "sr:00000000-0000-4000-8000-000000000002", Check: "desc", Status: checkStatusUnknown, Reason: reasonTargetLimitExceeded},
	}
	result, err := buildConfigCheckResult(verdicts, run.coverage(), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.Summary, "1 endpoints not checked") || !strings.Contains(result.Summary, "3 endpoints not delivered") {
		t.Fatalf("summary = %q", result.Summary)
	}
	var details struct {
		Coverage checkCoverage `json:"coverage"`
	}
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatal(err)
	}
	want := checkCoverage{Delivered: 2, Total: 5, CoreCapped: true, NotDelivered: 3, Skipped: 1}
	if details.Coverage != want {
		t.Fatalf("coverage = %#v, want %#v", details.Coverage, want)
	}
}

func rawConfig(t *testing.T, doc string) map[string]json.RawMessage {
	t.Helper()
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(doc), &raw); err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestParseConfigCheckRunFromScheduleRun(t *testing.T) {
	const items = `"target_items":{"entity":"devices","items":[{"uid":"sr:00000000-0000-4000-8000-000000000001","fields":{"switch_port_attachment":{"switch_hostname":"switch01.example.com","port":"1"}}}]}`
	for name, doc := range map[string]string{
		// The config form stores the definition as JSON text.
		"string definition": `{"config_check":"{\"block_end\":\"exit\",\"checks\":[{\"name\":\"desc\",\"patterns\":[\"name \\\"x\\\"\"]}]}",
			"action_invocation":{"action_id":"opentext-nom.interface.check",` + items + `}}`,
		"object in input_values": `{"action_invocation":{"action_id":"opentext-nom.interface.check",
			"input_values":{"config_check":{"block_end":"exit","checks":[{"name":"desc","patterns":["name"]}]}},` + items + `}}`,
	} {
		run, err := parseConfigCheckRun(rawConfig(t, doc))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if run.checks.BlockEnd != "exit" || len(run.checks.Checks) != 1 || len(run.items) != 1 {
			t.Fatalf("%s: run = %#v", name, run)
		}
	}
}

func TestParseConfigCheckRunRejectsMissingParts(t *testing.T) {
	for name, doc := range map[string]string{
		"no definition":  `{"action_invocation":{"target_items":{"items":[]}}}`,
		"bad definition": `{"config_check":"{not json","action_invocation":{"target_items":{"items":[]}}}`,
		"no targets":     `{"config_check":{"checks":[{"name":"desc","patterns":["x"]}]},"action_invocation":{}}`,
		"wrong entity":   `{"config_check":{"checks":[{"name":"desc","patterns":["x"]}]},"action_invocation":{"target_items":{"entity":"interfaces","items":[]}}}`,
	} {
		if _, err := parseConfigCheckRun(rawConfig(t, doc)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestInventoryConfigIgnoresCheckOnlyKeys(t *testing.T) {
	raw := rawConfig(t, `{
		"instance_id":"na-lab",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper",
		"config_check":"{}",
		"target_query":"in:devices",
		"target_fields":["switch_port_attachment"]
	}`)
	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseConfig(payload); err != nil {
		t.Fatalf("inventory config with check-only keys: %v", err)
	}
}

func mergeItem(base, extra map[string]any) map[string]any {
	for key, value := range extra {
		base[key] = value
	}
	return base
}
