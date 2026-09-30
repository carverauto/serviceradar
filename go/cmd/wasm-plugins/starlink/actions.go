package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

const (
	actionRebootTerminal   = "starlink.reboot_terminal"
	actionRebootRouter     = "starlink.reboot_router"
	actionSwapTerminal     = "starlink.swap_terminal"
	actionChangeProduct    = "starlink.change_product"
	actionDeactivateLine   = "starlink.deactivate_line"
	actionReactivateLine   = "starlink.reactivate_line"
	actionRetryDelaySecond = 30
)

func isManagementAction(id string) bool {
	switch id {
	case actionRebootTerminal, actionRebootRouter, actionSwapTerminal,
		actionChangeProduct, actionDeactivateLine, actionReactivateLine:
		return true
	}
	return false
}

// actionError is a failed action step. Retryable errors (rate limit,
// upstream failure, spent request budget) end the run as polling with the
// progress so far, so the dispatcher resumes; anything else fails the action.
type actionError struct {
	class     string
	message   string
	retryable bool
}

func (e *actionError) Error() string { return e.message }

func stepError(step string, err error) *actionError {
	code := errorCode(err)
	switch code {
	case "starlink_rate_limited", "starlink_upstream_error", "starlink_request_budget_exhausted", "starlink_request_failed":
		return &actionError{class: "retryable", message: step + ": " + code, retryable: true}
	}
	return &actionError{class: "vendor_rejected", message: step + ": " + code}
}

func preconditionError(message string) *actionError {
	return &actionError{class: "precondition_failed", message: message}
}

// actionRun carries one invocation through its steps. Completed holds the
// steps already done, persisted in continuation state; every step also
// re-reads vendor state before acting, so a retry that repeats a step whose
// result was never recorded does not repeat the mutation.
type actionRun struct {
	client    *apiClient
	cfg       Config
	completed []string
	state     map[string]any
}

func (r *actionRun) done(step string) bool {
	for _, s := range r.completed {
		if s == step {
			return true
		}
	}
	return false
}

func (r *actionRun) finish(step string) { r.completed = append(r.completed, step) }

func (r *actionRun) stateString(key string) string {
	v, _ := r.state[key].(string)
	return v
}

// runManagementAction executes one management action and returns its result.
func runManagementAction(cfg Config, doer httpDoer) *sdk.ActionResult {
	inv := cfg.Invocation
	run := &actionRun{client: newAPIClient(doer, cfg), cfg: cfg, state: map[string]any{}}
	if raw := inv.Get("continuation_state"); raw.IsObject() {
		for _, s := range raw.Get("completed_steps").Array() {
			run.completed = append(run.completed, s.String())
		}
		raw.Get("context").ForEach(func(k, v gjson.Result) bool {
			run.state[k.String()] = v.Value()
			return true
		})
	}

	terminalID, routerID := targetVendorIDs(inv)
	inputs := inv.Get("input_values")

	var err *actionError
	var summary map[string]any
	switch cfg.ActionID {
	case actionRebootTerminal:
		summary, err = run.reboot("/user-terminals/", terminalID, "terminal")
	case actionRebootRouter:
		summary, err = run.reboot("/routers/", routerID, "router")
	case actionSwapTerminal:
		summary, err = run.swapTerminal(terminalID, strings.TrimSpace(inputs.Get("new_device_id").String()))
	case actionChangeProduct, actionReactivateLine:
		summary, err = run.setProduct(terminalID, strings.TrimSpace(inputs.Get("product_reference_id").String()),
			cfg.ActionID == actionReactivateLine)
	case actionDeactivateLine:
		summary, err = run.deactivateLine(terminalID, inputs.Get("end_now").Bool(),
			strings.TrimSpace(inputs.Get("reason").String()))
	default:
		return sdk.ActionFailed("unsupported_action", "starlink_action_unsupported")
	}

	continuation := map[string]any{"completed_steps": run.completed, "context": run.state}
	if err != nil {
		if err.retryable {
			return sdk.ActionPolling(err.message).
				WithContinuationState(continuation).
				WithNextPollDelay(actionRetryDelaySecond).
				WithSummary("completed_steps", run.completed)
		}
		return sdk.ActionFailed(err.class, err.message).
			WithContinuationState(continuation).
			WithSummary("completed_steps", run.completed)
	}
	result := sdk.ActionSucceeded(cfg.ActionID+" completed").WithSummary("completed_steps", run.completed)
	for k, v := range summary {
		result = result.WithSummary(k, v)
	}
	return result
}

// targetVendorIDs reads the target device's vendor IDs from the plugin-owned
// integration identifiers the dispatcher attaches to the target snapshot.
func targetVendorIDs(inv gjson.Result) (terminalID, routerID string) {
	for _, target := range inv.Get("targets").Array() {
		for _, id := range target.Get("attributes.integration_ids").Array() {
			v := id.String()
			switch {
			case strings.HasPrefix(v, terminalIDPrefix) && terminalID == "":
				terminalID = normalizeTerminalID(strings.TrimPrefix(v, terminalIDPrefix))
			case strings.HasPrefix(v, routerIDPrefix) && routerID == "":
				routerID = normalizeRouterID("Router-" + strings.TrimPrefix(v, routerIDPrefix))
			}
		}
	}
	return terminalID, routerID
}

func (r *actionRun) reboot(pathPrefix, vendorID, kind string) (map[string]any, *actionError) {
	if vendorID == "" {
		return nil, preconditionError("target is not a Starlink " + kind)
	}
	if !r.done("reboot") {
		if _, err := r.client.call(http.MethodPost, pathPrefix+url.PathEscape(vendorID)+"/reboot", nil, nil, 0); err != nil {
			return nil, stepError("reboot", err)
		}
		r.finish("reboot")
	}
	return map[string]any{"kind": kind}, nil
}

// terminalRecord reads one terminal by vendor ID or, for devices not yet on
// the account, by kit or dish serial.
func (r *actionRun) terminalRecord(query url.Values) (gjson.Result, bool, error) {
	var found gjson.Result
	_, err := r.client.listPages("/user-terminals", query, func(row gjson.Result) {
		if !found.Exists() {
			found = row
		}
	})
	return found, found.Exists(), err
}

func (r *actionRun) terminalByID(id string) (gjson.Result, bool, error) {
	return r.terminalRecord(url.Values{"userTerminalIds": {id}})
}

// terminalByDevice finds a terminal by terminal ID, kit serial or dish serial.
// The vendor search is a substring match, so only an exact match on one of
// the three identifiers is accepted.
func (r *actionRun) terminalByDevice(device string) (gjson.Result, bool, error) {
	wantID := normalizeTerminalID(device)
	wantSerial := normalizeSerial(device)
	var found gjson.Result
	_, err := r.client.listPages("/user-terminals", url.Values{"searchString": {device}}, func(row gjson.Result) {
		if found.Exists() {
			return
		}
		if (wantID != "" && normalizeTerminalID(row.Get("userTerminalId").String()) == wantID) ||
			(wantSerial != "" && (normalizeSerial(row.Get("kitSerialNumber").String()) == wantSerial ||
				normalizeSerial(row.Get("dishSerialNumber").String()) == wantSerial)) {
			found = row
		}
	})
	return found, found.Exists(), err
}

// lineOf resolves the target terminal's current service line.
func (r *actionRun) lineOf(terminalID string) (string, *actionError) {
	if terminalID == "" {
		return "", preconditionError("target is not a Starlink terminal")
	}
	if sl := r.stateString("service_line"); sl != "" {
		return sl, nil
	}
	row, ok, err := r.terminalByID(terminalID)
	if err != nil {
		return "", stepError("preflight", err)
	}
	if !ok {
		return "", preconditionError("terminal is not on the account")
	}
	sl := trimmed(row, "serviceLineNumber")
	if sl == "" {
		return "", preconditionError("terminal has no service line")
	}
	r.state["service_line"] = sl
	return sl, nil
}

// swapTerminal replaces the target terminal on its service line with another
// terminal: remove the old one from the line, put the new one on the account
// and the line, and re-apply the L2VPN circuits removal cleared.
func (r *actionRun) swapTerminal(oldID, newDevice string) (map[string]any, *actionError) {
	if newDevice == "" || !jsonSafeID(newDevice) {
		return nil, preconditionError("new_device_id must be a terminal ID, kit serial or dish serial")
	}
	sl, aerr := r.lineOf(oldID)
	if aerr != nil {
		return nil, aerr
	}

	if !r.done("preflight") {
		old, _, err := r.terminalByID(oldID)
		if err != nil {
			return nil, stepError("preflight", err)
		}
		circuits := old.Get("l2VpnCircuits")
		if !circuits.IsArray() {
			circuits = gjson.Parse("[]")
		}
		r.state["l2vpn"] = circuits.Raw
		if err := r.checkLineCapacity(sl); err != nil {
			return nil, err
		}
		r.finish("preflight")
	}

	if !r.done("remove_old") {
		old, onAccount, err := r.terminalByID(oldID)
		if err != nil {
			return nil, stepError("remove_old", err)
		}
		if onAccount && trimmed(old, "serviceLineNumber") == sl {
			path := "/service-lines/" + url.PathEscape(sl) + "/user-terminals/" + url.PathEscape(oldID)
			if _, err := r.client.call(http.MethodDelete, path, nil, nil, 0); err != nil {
				return nil, stepError("remove_old", err)
			}
		}
		r.finish("remove_old")
	}

	if !r.done("add_new_to_account") {
		row, ok, err := r.terminalByDevice(newDevice)
		if err != nil {
			return nil, stepError("add_new_to_account", err)
		}
		if !ok {
			body, _ := json.Marshal(map[string]string{"deviceId": newDevice})
			if _, err := r.client.call(http.MethodPost, "/user-terminals", nil, body, 0); err != nil {
				return nil, stepError("add_new_to_account", err)
			}
			if row, ok, err = r.terminalByDevice(newDevice); err != nil || !ok {
				return nil, stepError("add_new_to_account", &apiError{code: "starlink_new_terminal_not_found"})
			}
		}
		newID := normalizeTerminalID(row.Get("userTerminalId").String())
		if newID == "" {
			return nil, preconditionError("new terminal has no terminal ID")
		}
		if other := trimmed(row, "serviceLineNumber"); other != "" && other != sl {
			return nil, preconditionError("new terminal is already on another service line")
		}
		r.state["new_terminal"] = newID
		r.finish("add_new_to_account")
	}
	newID := r.stateString("new_terminal")

	if !r.done("add_new_to_line") {
		row, _, err := r.terminalByID(newID)
		if err != nil {
			return nil, stepError("add_new_to_line", err)
		}
		if trimmed(row, "serviceLineNumber") != sl {
			body, _ := json.Marshal(map[string]string{"deviceId": newID})
			if _, err := r.client.call(http.MethodPost, "/service-lines/"+url.PathEscape(sl)+"/user-terminals", nil, body, 0); err != nil {
				return nil, stepError("add_new_to_line", err)
			}
		}
		r.finish("add_new_to_line")
	}

	if !r.done("reapply_l2vpn") {
		if body := l2vpnRequestBody(gjson.Parse(r.stateString("l2vpn"))); body != nil {
			if _, err := r.client.call(http.MethodPut, "/user-terminals/"+url.PathEscape(newID)+"/l2vpn", nil, body, 0); err != nil {
				return nil, stepError("reapply_l2vpn", err)
			}
		}
		r.finish("reapply_l2vpn")
	}

	if !r.done("verify") {
		row, _, err := r.terminalByID(newID)
		if err != nil {
			return nil, stepError("verify", err)
		}
		if trimmed(row, "serviceLineNumber") != sl {
			return nil, preconditionError("new terminal is not on the service line after the swap")
		}
		r.finish("verify")
	}
	return map[string]any{"new_terminal_device_id": terminalIDPrefix + newID}, nil
}

// checkLineCapacity refuses a swap the product would reject: the line may hold
// at most maxNumberOfUserTerminals (null means unlimited), and the swap keeps
// the count unchanged, so a line already over its limit cannot take a swap.
func (r *actionRun) checkLineCapacity(sl string) *actionError {
	line, err := r.client.call(http.MethodGet, "/service-lines/"+url.PathEscape(sl), nil, nil, 0)
	if err != nil {
		return stepError("preflight", err)
	}
	product := trimmed(line, "productReferenceId")
	limit := -1
	_, err = r.client.listPages("/products", nil, func(row gjson.Result) {
		if trimmed(row, "productReferenceId") == product {
			if max := row.Get("maxNumberOfUserTerminals"); max.Type == gjson.Number {
				limit = int(max.Int())
			}
		}
	})
	if err != nil {
		return stepError("preflight", err)
	}
	if limit < 0 {
		return nil
	}
	count := 0
	if _, err := r.client.listPages("/user-terminals", url.Values{"serviceLineNumbers": {sl}}, func(gjson.Result) { count++ }); err != nil {
		return stepError("preflight", err)
	}
	if count > limit {
		return preconditionError("service line already exceeds its product's terminal limit of " + strconv.Itoa(limit))
	}
	return nil
}

// l2vpnRequestBody converts circuit definitions read before the swap into the
// set-circuits request; nil when there is nothing to re-apply.
func l2vpnRequestBody(circuits gjson.Result) []byte {
	var out []map[string]any
	for _, c := range circuits.Array() {
		ids := []string{}
		for _, id := range c.Get("circuitIds").Array() {
			ids = append(ids, id.String())
		}
		if len(ids) == 0 && trimmed(c, "circuitId") != "" {
			ids = append(ids, trimmed(c, "circuitId"))
		}
		if len(ids) == 0 {
			continue
		}
		vlans := []int64{}
		for _, v := range c.Get("customerVlans").Array() {
			vlans = append(vlans, v.Int())
		}
		entry := map[string]any{"circuitIds": ids, "customerVlans": vlans}
		if v := c.Get("serviceVlan"); v.Type == gjson.Number {
			entry["serviceVlan"] = v.Int()
		}
		if v := c.Get("customerVlanRemap"); v.Type == gjson.Number {
			entry["customerVlanRemap"] = v.Int()
		}
		out = append(out, entry)
	}
	if len(out) == 0 {
		return nil
	}
	body, _ := json.Marshal(out)
	return body
}

// setProduct changes the service line's product; on an inactive line the same
// call reactivates it.
func (r *actionRun) setProduct(terminalID, product string, reactivate bool) (map[string]any, *actionError) {
	if product == "" || !jsonSafeID(product) {
		return nil, preconditionError("product_reference_id is required")
	}
	sl, aerr := r.lineOf(terminalID)
	if aerr != nil {
		return nil, aerr
	}
	if !r.done("preflight") {
		line, err := r.client.call(http.MethodGet, "/service-lines/"+url.PathEscape(sl), nil, nil, 0)
		if err != nil {
			return nil, stepError("preflight", err)
		}
		if reactivate && line.Get("active").Bool() {
			return nil, preconditionError("service line is already active")
		}
		known := false
		if _, err := r.client.listPages("/products", nil, func(row gjson.Result) {
			known = known || trimmed(row, "productReferenceId") == product
		}); err != nil {
			return nil, stepError("preflight", err)
		}
		if !known {
			return nil, preconditionError("product is not available to this account")
		}
		r.finish("preflight")
	}
	if !r.done("set_product") {
		body, _ := json.Marshal(map[string]string{"productReferenceId": product})
		if _, err := r.client.call(http.MethodPut, "/service-lines/"+url.PathEscape(sl)+"/product", nil, body, 0); err != nil {
			return nil, stepError("set_product", err)
		}
		r.finish("set_product")
	}
	return map[string]any{"service_line": sl, "product_reference_id": product}, nil
}

func (r *actionRun) deactivateLine(terminalID string, endNow bool, reason string) (map[string]any, *actionError) {
	sl, aerr := r.lineOf(terminalID)
	if aerr != nil {
		return nil, aerr
	}
	if !r.done("deactivate") {
		line, err := r.client.call(http.MethodGet, "/service-lines/"+url.PathEscape(sl), nil, nil, 0)
		if err != nil {
			return nil, stepError("deactivate", err)
		}
		if line.Get("active").Bool() {
			q := url.Values{"endNow": {strconv.FormatBool(endNow)}}
			if reason != "" {
				q.Set("reasonForCancellation", reason)
			}
			if _, err := r.client.call(http.MethodDelete, "/service-lines/"+url.PathEscape(sl), q, nil, 0); err != nil {
				return nil, stepError("deactivate", err)
			}
		}
		r.finish("deactivate")
	}
	return map[string]any{"service_line": sl, "end_now": endNow}, nil
}
