package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// fakeVendor is a small stateful model of the Management API surface the
// actions use, so a test observes the resulting vendor state rather than a
// request script. All identifiers are invented.
type fakeVendor struct {
	t         *testing.T
	terminals map[string]*fakeTerminal // by terminal ID
	lines     map[string]*fakeLine
	maxPerSL  int // -1 = unlimited
	failOnce  map[string]int
	mutations []string
}

type fakeTerminal struct {
	id, kit, sl string
	l2vpn       string // raw JSON array
}

type fakeLine struct {
	product string
	active  bool
}

const (
	testNewTerminal = "c3c3c3c3-00000003-00000003"
	testNewKit      = "KITTEST0000003"
)

func newFakeVendor(t *testing.T) *fakeVendor {
	return &fakeVendor{
		t: t,
		terminals: map[string]*fakeTerminal{
			testTerminalA: {id: testTerminalA, kit: "KITTEST0000001", sl: testServiceLine,
				l2vpn: `[{"circuitIds":["circuit-test-1"],"customerVlans":[101,102],"serviceVlan":200}]`},
		},
		lines:    map[string]*fakeLine{testServiceLine: {product: "example-product", active: true}},
		maxPerSL: 1,
		failOnce: map[string]int{},
	}
}

func (f *fakeVendor) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	u, _ := url.Parse(req.URL)
	path := strings.TrimPrefix(u.Path, "/api/public/v2")
	key := req.Method + " " + path
	if n := f.failOnce[key]; n > 0 {
		f.failOnce[key] = n - 1
		return &sdk.HTTPResponse{Status: 503, Body: []byte("unavailable")}, nil
	}
	if req.Method != http.MethodGet {
		f.mutations = append(f.mutations, key)
	}
	q := u.Query()
	ok := func(content string) (*sdk.HTTPResponse, error) {
		return &sdk.HTTPResponse{Status: 200, Body: []byte(envelope(content))}, nil
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")

	switch {
	case req.Method == http.MethodGet && path == "/user-terminals":
		var rows []string
		for _, term := range f.terminals {
			if id := q.Get("userTerminalIds"); id != "" && id != term.id {
				continue
			}
			if s := q.Get("searchString"); s != "" && !strings.Contains(term.id+term.kit, s) {
				continue
			}
			if sl := q.Get("serviceLineNumbers"); sl != "" && sl != term.sl {
				continue
			}
			l2 := term.l2vpn
			if l2 == "" {
				l2 = "[]"
			}
			rows = append(rows, `{"userTerminalId":"`+term.id+`","kitSerialNumber":"`+term.kit+
				`","serviceLineNumber":`+jsonStringOrNull(term.sl)+`,"l2VpnCircuits":`+l2+`,"routers":[]}`)
		}
		return ok(`{"pageIndex":0,"isLastPage":true,"results":[` + strings.Join(rows, ",") + `]}`)
	case req.Method == http.MethodGet && path == "/products":
		max := "null"
		if f.maxPerSL >= 0 {
			max = itoa(f.maxPerSL)
		}
		return ok(`{"isLastPage":true,"results":[{"productReferenceId":"example-product","maxNumberOfUserTerminals":` + max +
			`},{"productReferenceId":"example-product-2","maxNumberOfUserTerminals":null}]}`)
	case req.Method == http.MethodGet && len(parts) == 2 && parts[0] == "service-lines":
		line := f.lines[parts[1]]
		return ok(`{"serviceLineNumber":"` + parts[1] + `","productReferenceId":"` + line.product + `","active":` + boolJSON(line.active) + `}`)
	case req.Method == http.MethodDelete && len(parts) == 4 && parts[2] == "user-terminals":
		f.terminals[parts[3]].sl = ""
		f.terminals[parts[3]].l2vpn = ""
		return ok(`null`)
	case req.Method == http.MethodPost && path == "/user-terminals":
		device := gjson.GetBytes(req.Body, "deviceId").String()
		if device != testNewKit {
			return &sdk.HTTPResponse{Status: 422, Body: []byte(`{"isValid":false}`)}, nil
		}
		f.terminals[testNewTerminal] = &fakeTerminal{id: testNewTerminal, kit: testNewKit}
		return ok(`null`)
	case req.Method == http.MethodPost && len(parts) == 3 && parts[2] == "user-terminals":
		f.terminals[gjson.GetBytes(req.Body, "deviceId").String()].sl = parts[1]
		return ok(`null`)
	case req.Method == http.MethodPut && len(parts) == 3 && parts[2] == "l2vpn":
		f.terminals[parts[1]].l2vpn = string(req.Body)
		return ok(`null`)
	case req.Method == http.MethodPut && len(parts) == 3 && parts[2] == "product":
		f.lines[parts[1]].product = gjson.GetBytes(req.Body, "productReferenceId").String()
		f.lines[parts[1]].active = true
		return ok(`null`)
	case req.Method == http.MethodDelete && len(parts) == 2 && parts[0] == "service-lines":
		f.lines[parts[1]].active = false
		return ok(`null`)
	case req.Method == http.MethodPost && strings.HasSuffix(path, "/reboot"):
		return ok(`null`)
	}
	f.t.Fatalf("unexpected vendor request %s", key)
	return nil, nil
}

func jsonStringOrNull(v string) string {
	if v == "" {
		return "null"
	}
	return `"` + v + `"`
}

func invocationConfig(t *testing.T, actionID string, inputs map[string]any, continuation map[string]any) Config {
	t.Helper()
	inv := map[string]any{
		"action_id":    actionID,
		"input_values": inputs,
		"targets": []any{map[string]any{
			"kind": "device", "device_uid": "sr:example-device",
			"attributes": map[string]any{"integration_ids": []string{"starlink:ut:" + testTerminalA}},
		}},
	}
	if continuation != nil {
		inv["continuation_state"] = continuation
	}
	raw, _ := json.Marshal(map[string]any{"action_invocation": inv})
	return mustConfig(t, string(raw))
}

func continuationOf(t *testing.T, r *sdk.ActionResult) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(r.ContinuationState)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return out
}

func TestSwapTerminalEndToEnd(t *testing.T) {
	vendor := newFakeVendor(t)
	result := runManagementAction(invocationConfig(t, actionSwapTerminal, map[string]any{"new_device_id": testNewKit}, nil), vendor)

	if result.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("status %q: %s %s", result.Status, result.ErrorClass, result.ErrorMessage)
	}
	if vendor.terminals[testTerminalA].sl != "" {
		t.Fatal("old terminal is still on the service line")
	}
	moved := vendor.terminals[testNewTerminal]
	if moved.sl != testServiceLine {
		t.Fatalf("new terminal service line = %q", moved.sl)
	}
	// Removing the old terminal cleared its circuits; the swap must carry them
	// over to the new terminal.
	if gjson.Get(moved.l2vpn, "0.circuitIds.0").String() != "circuit-test-1" ||
		gjson.Get(moved.l2vpn, "0.customerVlans.1").Int() != 102 || gjson.Get(moved.l2vpn, "0.serviceVlan").Int() != 200 {
		t.Fatalf("L2VPN circuits not re-applied: %s", moved.l2vpn)
	}
}

func TestSwapTerminalResumesAfterRetryableFailure(t *testing.T) {
	vendor := newFakeVendor(t)
	vendor.failOnce["POST /service-lines/"+testServiceLine+"/user-terminals"] = 1
	inputs := map[string]any{"new_device_id": testNewKit}

	first := runManagementAction(invocationConfig(t, actionSwapTerminal, inputs, nil), vendor)
	if first.Status != sdk.ActionStatusPolling || first.NextPollDelaySeconds == 0 {
		t.Fatalf("a vendor 503 must defer the action for a retry, got %q", first.Status)
	}
	state := continuationOf(t, first)
	done, _ := json.Marshal(state["completed_steps"])
	if string(done) != `["preflight","remove_old","add_new_to_account"]` {
		t.Fatalf("completed steps = %s", done)
	}

	mutationsBefore := len(vendor.mutations)
	second := runManagementAction(invocationConfig(t, actionSwapTerminal, inputs, state), vendor)
	if second.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("resume status %q: %s", second.Status, second.ErrorMessage)
	}
	for _, m := range vendor.mutations[mutationsBefore:] {
		if strings.HasPrefix(m, "DELETE") || m == "POST /user-terminals" {
			t.Fatalf("resume repeated a completed mutation: %s", m)
		}
	}
	if vendor.terminals[testNewTerminal].sl != testServiceLine {
		t.Fatal("resumed swap did not finish")
	}
}

func TestSwapTerminalRerunWithoutStateDoesNotRepeatMutations(t *testing.T) {
	vendor := newFakeVendor(t)
	inputs := map[string]any{"new_device_id": testNewKit}
	if r := runManagementAction(invocationConfig(t, actionSwapTerminal, inputs, nil), vendor); r.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("first run: %q", r.Status)
	}
	// The result of a completed run was lost; the same invocation runs again
	// from scratch. Every step re-reads vendor state, so nothing is repeated.
	before := len(vendor.mutations)
	second := runManagementAction(invocationConfig(t, actionSwapTerminal, inputs, nil), vendor)
	if second.Status != sdk.ActionStatusFailed || second.ErrorClass != "precondition_failed" {
		t.Fatalf("re-running a finished swap must stop at preflight (old terminal has no line), got %q", second.Status)
	}
	if len(vendor.mutations) != before {
		t.Fatalf("re-run mutated vendor state: %v", vendor.mutations[before:])
	}
}

func TestSwapTerminalPreflightRejectsOverLimitLine(t *testing.T) {
	vendor := newFakeVendor(t)
	vendor.terminals["d4d4d4d4-00000004-00000004"] = &fakeTerminal{id: "d4d4d4d4-00000004-00000004", kit: "KITTEST0000004", sl: testServiceLine}
	result := runManagementAction(invocationConfig(t, actionSwapTerminal, map[string]any{"new_device_id": testNewKit}, nil), vendor)
	if result.Status != sdk.ActionStatusFailed || result.ErrorClass != "precondition_failed" {
		t.Fatalf("status %q class %q", result.Status, result.ErrorClass)
	}
	if len(vendor.mutations) != 0 {
		t.Fatalf("preflight failure must precede any mutation: %v", vendor.mutations)
	}
}

func TestManagementActionRequiresStarlinkTarget(t *testing.T) {
	raw := `{"action_invocation":{"action_id":"` + actionRebootTerminal + `","targets":[{"kind":"device","device_uid":"sr:other","attributes":{"integration_ids":["netbox:example:device:7"]}}]}}`
	result := runManagementAction(mustConfig(t, raw), newFakeVendor(t))
	if result.Status != sdk.ActionStatusFailed || result.ErrorClass != "precondition_failed" {
		t.Fatalf("a device without a Starlink identifier must be refused, got %q", result.Status)
	}
}

func TestRebootTerminalCallsVendorReboot(t *testing.T) {
	vendor := newFakeVendor(t)
	if r := runManagementAction(invocationConfig(t, actionRebootTerminal, nil, nil), vendor); r.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("status %q", r.Status)
	}
	if len(vendor.mutations) != 1 || vendor.mutations[0] != "POST /user-terminals/"+testTerminalA+"/reboot" {
		t.Fatalf("mutations = %v", vendor.mutations)
	}
}

func TestLifecycleActions(t *testing.T) {
	vendor := newFakeVendor(t)
	if r := runManagementAction(invocationConfig(t, actionChangeProduct, map[string]any{"product_reference_id": "unknown-product"}, nil), vendor); r.ErrorClass != "precondition_failed" {
		t.Fatalf("an unavailable product must be refused before any mutation: %q", r.Status)
	}
	if r := runManagementAction(invocationConfig(t, actionDeactivateLine, map[string]any{"end_now": true}, nil), vendor); r.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("deactivate: %q", r.Status)
	}
	if vendor.lines[testServiceLine].active {
		t.Fatal("line still active")
	}
	if r := runManagementAction(invocationConfig(t, actionReactivateLine, map[string]any{"product_reference_id": "example-product-2"}, nil), vendor); r.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("reactivate: %q %s", r.Status, r.ErrorMessage)
	}
	line := vendor.lines[testServiceLine]
	if !line.active || line.product != "example-product-2" {
		t.Fatalf("line after reactivate = %+v", line)
	}
	if r := runManagementAction(invocationConfig(t, actionReactivateLine, map[string]any{"product_reference_id": "example-product"}, nil), vendor); r.ErrorClass != "precondition_failed" {
		t.Fatal("reactivating an active line must be refused")
	}
}

func TestSwapTerminalStepSkipsMutationAlreadyApplied(t *testing.T) {
	vendor := newFakeVendor(t)
	l2vpn := vendor.terminals[testTerminalA].l2vpn
	// A previous attempt removed the old terminal but died before recording
	// the step: continuation state says only preflight is done.
	vendor.terminals[testTerminalA].sl = ""
	state := map[string]any{
		"completed_steps": []string{"preflight"},
		"context":         map[string]any{"service_line": testServiceLine, "l2vpn": l2vpn},
	}
	result := runManagementAction(invocationConfig(t, actionSwapTerminal, map[string]any{"new_device_id": testNewKit}, state), vendor)
	if result.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("status %q: %s", result.Status, result.ErrorMessage)
	}
	for _, m := range vendor.mutations {
		if strings.HasPrefix(m, "DELETE") {
			t.Fatalf("the old terminal was already off the line; the removal must not be sent again: %v", vendor.mutations)
		}
	}
	if gjson.Get(vendor.terminals[testNewTerminal].l2vpn, "0.circuitIds.0").String() != "circuit-test-1" {
		t.Fatal("circuits captured before the interruption must still be re-applied")
	}
}
