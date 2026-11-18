package main

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	statusHealthy  = "healthy"
	statusDegraded = "degraded"
	statusDown     = "down"
	statusUnknown  = "unknown"

	redactedPlaceholder = "[REDACTED]"
	maxSnapshotBytes    = 16000
)

type interpMode int

const (
	interpModeRaw interpMode = iota
	interpModeURL
	interpModeHost
	interpModeHeader
)

type evalContext struct {
	inputs       map[string]any
	target       map[string]any
	vars         map[string]any
	stepVars     map[string]map[string]any
	secretValues []string
}

func newEvalContext(inputs []map[string]any, target TargetSpec) *evalContext {
	inMap := make(map[string]any, len(inputs))
	for _, entry := range inputs {
		name := firstNonEmptyString(entry["name"], entry["key"], entry["id"])
		if name == "" {
			continue
		}
		if v, ok := entry["value"]; ok {
			inMap[name] = v
		} else if d, ok := entry["default"]; ok {
			inMap[name] = d
		}
	}

	tgtMap := map[string]any{
		"target_key":        target.TargetKey,
		"target_kind":       target.TargetKind,
		"device_uid":        target.DeviceUID,
		"uid":               target.DeviceUID,
		"service_target_id": target.ServiceTargetID,
		"url":               target.URL,
		"host":              target.Host,
		"hostname":          target.Hostname,
		"ip":                target.IP,
		"port":              target.Port,
	}
	for k, v := range target.Attributes {
		if _, exists := tgtMap[k]; !exists {
			tgtMap[k] = v
		}
	}

	return &evalContext{
		inputs:   inMap,
		target:   tgtMap,
		vars:     map[string]any{},
		stepVars: map[string]map[string]any{},
	}
}

func (c *evalContext) setStepVar(stepID, name string, val any) {
	if c == nil || name == "" {
		return
	}
	c.vars[name] = val
	if stepID != "" {
		if c.stepVars[stepID] == nil {
			c.stepVars[stepID] = map[string]any{}
		}
		c.stepVars[stepID][name] = val
	}
}

func (c *evalContext) markSecret(secret string) {
	trimmed := strings.TrimSpace(secret)
	if c == nil || trimmed == "" {
		return
	}
	for _, existing := range c.secretValues {
		if existing == trimmed {
			return
		}
	}
	c.secretValues = append(c.secretValues, trimmed)
}

func (c *evalContext) scrubString(s string) string {
	if s == "" {
		return ""
	}
	out := s
	if c != nil {
		for _, sec := range c.secretValues {
			if sec != "" && strings.Contains(out, sec) {
				out = strings.ReplaceAll(out, sec, redactedPlaceholder)
			}
		}
	}
	return scrubCommonAuthTokens(out)
}

func (c *evalContext) scrubMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		if isSensitiveKey(k) {
			out[k] = redactedPlaceholder
			continue
		}
		out[k] = c.scrubAny(v)
	}
	return out
}

func (c *evalContext) scrubAny(v any) any {
	switch typed := v.(type) {
	case string:
		return c.scrubString(typed)
	case map[string]any:
		return c.scrubMap(typed)
	case map[string]string:
		res := make(map[string]string, len(typed))
		for k, val := range typed {
			if isSensitiveKey(k) {
				res[k] = redactedPlaceholder
			} else {
				res[k] = c.scrubString(val)
			}
		}
		return res
	case []any:
		res := make([]any, len(typed))
		for i, item := range typed {
			res[i] = c.scrubAny(item)
		}
		return res
	case []map[string]any:
		res := make([]map[string]any, len(typed))
		for i, item := range typed {
			res[i] = c.scrubMap(item)
		}
		return res
	default:
		return v
	}
}

func (c *evalContext) interpolate(template string, mode interpMode) (string, error) {
	normalized := strings.ReplaceAll(template, "{{", "${")
	if normalized != template {
		normalized = strings.ReplaceAll(normalized, "}}", "}")
	}
	template = normalized
	if !strings.Contains(template, "${") {
		return template, nil
	}
	var sb strings.Builder
	rest := template
	for {
		idx := strings.Index(rest, "${")
		if idx < 0 {
			sb.WriteString(rest)
			break
		}
		sb.WriteString(rest[:idx])
		rest = rest[idx+2:]
		endIdx := strings.IndexByte(rest, '}')
		if endIdx < 0 {
			return "", sentinelError("unterminated template expression")
		}
		expr := strings.TrimSpace(rest[:endIdx])
		rest = rest[endIdx+1:]

		resolved, ok := c.lookupExpr(expr)
		if !ok {
			return "", sentinelError("unresolved template variable: " + expr)
		}
		strVal := valueToString(resolved)
		if err := validateInterpolatedValue(strVal, mode); err != nil {
			return "", err
		}
		sb.WriteString(strVal)
	}
	return sb.String(), nil
}

func (c *evalContext) lookupExpr(expr string) (any, bool) {
	if c == nil {
		return nil, false
	}
	parts := strings.Split(expr, ".")
	if len(parts) < 2 {
		v, ok := c.vars[expr]
		return v, ok
	}
	switch parts[0] {
	case "target":
		return lookupNestedMap(c.target, parts[1:])
	case "inputs":
		return lookupNestedMap(c.inputs, parts[1:])
	case "vars":
		return lookupNestedMap(c.vars, parts[1:])
	case "steps":
		if len(parts) < 3 {
			return nil, false
		}
		stepMap, ok := c.stepVars[parts[1]]
		if !ok {
			return nil, false
		}
		return lookupNestedMap(stepMap, parts[2:])
	default:
		return nil, false
	}
}

func lookupNestedMap(m map[string]any, keys []string) (any, bool) {
	var cur any = m
	for _, k := range keys {
		asMap, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		next, exists := asMap[k]
		if !exists || next == nil {
			return nil, false
		}
		cur = next
	}
	return cur, true
}

func validateInterpolatedValue(val string, mode interpMode) error {
	for i := 0; i < len(val); i++ {
		ch := val[i]
		if (ch < 0x20 && ch != '\t') || ch == 0x7f {
			if mode == interpModeRaw && (ch == '\n' || ch == '\r') {
				continue
			}
			return sentinelError("interpolated value contains control character")
		}
	}
	switch mode {
	case interpModeHost:
		if strings.ContainsAny(val, "/\\?#@ \t\r\n") {
			return sentinelError("interpolated host contains unsafe characters")
		}
	case interpModeHeader:
		if strings.ContainsAny(val, "\r\n") {
			return sentinelError("interpolated header contains CRLF")
		}
	case interpModeURL:
		if strings.ContainsAny(val, "\r\n\t ") {
			return sentinelError("interpolated url contains whitespace")
		}
	case interpModeRaw:
	}
	return nil
}

func evalExtractFieldNode(node NodeSpec, upstreams []NodeOutcome, ctx *evalContext) NodeOutcome {
	var src map[string]any
	if len(upstreams) > 0 {
		src = upstreams[0].Payload
	}
	if src == nil {
		src = map[string]any{}
	}

	var (
		rawVal any
		found  bool
	)
	sourceType := strings.ToLower(stringFromAny(node.Config["source_type"]))
	expr := stringFromAny(node.Config["expression"])
	jp := firstNonEmptyString(node.Config["json_path"], node.Config["path"])
	hdr := stringFromAny(node.Config["header"])
	pat := firstNonEmptyString(node.Config["regex"], node.Config["pattern"])
	field := stringFromAny(node.Config["field"])

	switch sourceType {
	case "jsonpath":
		if jp == "" {
			jp = expr
		}
	case "header":
		if hdr == "" {
			hdr = expr
		}
	case "regex":
		if pat == "" {
			pat = expr
		}
	case "field", "srql_field":
		if field == "" {
			field = expr
		}
	}

	if jp != "" {
		if bodyStr, ok := src["body"].(string); ok && strings.HasPrefix(strings.TrimSpace(bodyStr), "{") {
			var decoded any
			if json.Unmarshal([]byte(bodyStr), &decoded) == nil {
				rawVal, found = lookupJSONPath(decoded, jp)
			}
		}
		if !found {
			rawVal, found = lookupJSONPath(src, jp)
		}
	} else if hdr != "" {
		if hdrs, ok := src["headers"].(map[string]string); ok {
			if v := headerCaseInsensitive(hdrs, hdr); v != "" {
				rawVal, found = v, true
			}
		} else if hdrsAny, ok := src["headers"].(map[string]any); ok {
			for k, v := range hdrsAny {
				if strings.EqualFold(k, hdr) {
					rawVal, found = valueToString(v), true
					break
				}
			}
		}
	} else if pat != "" {
		sourceField := firstNonEmptyString(node.Config["source_field"], "body")
		text := valueToString(src[sourceField])
		if re, err := regexp.Compile(pat); err == nil {
			if m := re.FindStringSubmatch(text); len(m) > 1 {
				rawVal, found = m[1], true
			} else if len(m) == 1 {
				rawVal, found = m[0], true
			}
		}
	} else if field != "" {
		rawVal, found = src[field]
		if !found && strings.Contains(field, ".") {
			rawVal, found = lookupJSONPath(src, "$."+field)
		}
	} else if expr != "" {
		rawVal, found = src[expr]
	}

	if !found {
		if defVal, hasDef := node.Config["default"]; hasDef {
			rawVal = defVal
			found = true
		}
	}
	if !found {
		return NodeOutcome{
			Status:  statusUnknown,
			Verdict: statusUnknown,
			Summary: "field extraction produced no value",
			Value:   "",
			Payload: map[string]any{"extracted": false},
		}
	}

	castVal, ok := castExtractedValue(rawVal, stringFromAny(node.Config["cast"]))
	if !ok {
		return NodeOutcome{
			Status:  statusUnknown,
			Verdict: statusUnknown,
			Summary: "extracted value failed type cast",
			Value:   "",
			Payload: map[string]any{"extracted": false},
		}
	}

	outField := firstNonEmptyString(node.Config["output_key"], node.Config["as"], node.Config["output_field"], "value")
	scrubbed := ctx.scrubAny(castVal)
	return NodeOutcome{
		Status:  statusHealthy,
		Verdict: statusHealthy,
		Summary: "extracted " + outField,
		Value:   ctx.scrubString(valueToString(castVal)),
		Payload: map[string]any{
			"extracted": true,
			"value":     scrubbed,
			outField:    scrubbed,
		},
	}
}

func evalThresholdAssertNode(node NodeSpec, upstreams []NodeOutcome) NodeOutcome {
	var src map[string]any
	upstreamStatus := statusHealthy
	if len(upstreams) > 0 {
		src = upstreams[0].Payload
		upstreamStatus = upstreams[0].Status
	}
	if src == nil {
		src = map[string]any{}
	}

	passVerdict := firstNonEmptyString(node.Config["pass_verdict"], statusHealthy)
	warnVerdict := firstNonEmptyString(node.Config["warn_verdict"], statusDegraded)
	critVerdict := firstNonEmptyString(node.Config["crit_verdict"], statusDown)
	unknownVerdict := firstNonEmptyString(node.Config["unknown_verdict"], statusUnknown)

	failClosedField := stringFromAny(node.Config["fail_closed_field"])
	if failClosedField != "" && boolFromAny(src[failClosedField], false) {
		return NodeOutcome{
			Status:  statusDown,
			Verdict: critVerdict,
			Summary: fmt.Sprintf("fail-closed triggered on %s", failClosedField),
			Value:   critVerdict,
			Payload: map[string]any{"passed": false, "fail_closed": true, "verdict": critVerdict},
		}
	}
	if upstreamStatus == statusDown && boolFromAny(src["probe_failed"], false) {
		return NodeOutcome{
			Status:  statusDown,
			Verdict: critVerdict,
			Summary: "upstream probe failed",
			Value:   critVerdict,
			Payload: map[string]any{"passed": false, "probe_failed": true, "verdict": critVerdict},
		}
	}

	field := firstNonEmptyString(node.Config["field"], "value")
	actual, exists := src[field]
	if !exists && strings.Contains(field, ".") {
		actual, exists = lookupJSONPath(src, "$."+field)
	}
	if !exists && field == "value" && len(upstreams) > 0 && upstreams[0].Value != "" {
		actual, exists = upstreams[0].Value, true
	}
	if !exists {
		return NodeOutcome{
			Status:  statusUnknown,
			Verdict: unknownVerdict,
			Summary: "threshold field missing: " + field,
			Value:   unknownVerdict,
			Payload: map[string]any{"passed": false, "missing_field": field, "verdict": unknownVerdict},
		}
	}

	// Canonical SchemaValidator comparator objects: {"crit": {"op": ">=", "value": 10}, "warn": {...}}
	critMap, hasCritMap := node.Config["crit"].(map[string]any)
	warnMap, hasWarnMap := node.Config["warn"].(map[string]any)
	if hasCritMap || hasWarnMap {
		if hasCritMap {
			cOp := stringFromAny(critMap["op"])
			if cOp != "" && compareValues(actual, cOp, critMap["value"]) {
				return NodeOutcome{
					Status:  statusDown,
					Verdict: critVerdict,
					Summary: fmt.Sprintf("%s=%v matched critical threshold", field, actual),
					Value:   valueToString(actual),
					Payload: map[string]any{"passed": false, "matched_tier": "crit", "field": field, "actual": actual, "verdict": critVerdict},
				}
			}
		}
		if hasWarnMap {
			wOp := stringFromAny(warnMap["op"])
			if wOp != "" && compareValues(actual, wOp, warnMap["value"]) {
				return NodeOutcome{
					Status:  statusDegraded,
					Verdict: warnVerdict,
					Summary: fmt.Sprintf("%s=%v matched warning threshold", field, actual),
					Value:   valueToString(actual),
					Payload: map[string]any{"passed": false, "matched_tier": "warn", "field": field, "actual": actual, "verdict": warnVerdict},
				}
			}
		}
		return NodeOutcome{
			Status:  statusHealthy,
			Verdict: passVerdict,
			Summary: fmt.Sprintf("%s=%v within thresholds", field, actual),
			Value:   valueToString(actual),
			Payload: map[string]any{"passed": true, "matched_tier": "pass", "field": field, "actual": actual, "verdict": passVerdict},
		}
	}

	if op := stringFromAny(node.Config["op"]); op != "" {
		expected := node.Config["value"]
		if expected == nil {
			expected = node.Config["threshold"]
		}
		if compareValues(actual, op, expected) {
			return NodeOutcome{
				Status:  statusHealthy,
				Verdict: passVerdict,
				Summary: fmt.Sprintf("%s %s passed", field, op),
				Value:   valueToString(actual),
				Payload: map[string]any{"passed": true, "field": field, "actual": actual, "verdict": passVerdict},
			}
		}
		failStatus := normalizeStatusString(firstNonEmptyString(node.Config["fail_status"], statusDown))
		failVerdict := critVerdict
		if failStatus == statusDegraded {
			failVerdict = warnVerdict
		}
		return NodeOutcome{
			Status:  failStatus,
			Verdict: failVerdict,
			Summary: fmt.Sprintf("%s %s assertion failed", field, op),
			Value:   valueToString(actual),
			Payload: map[string]any{"passed": false, "field": field, "actual": actual, "verdict": failVerdict},
		}
	}

	actualNum, ok := floatFromAny(actual)
	if !ok {
		return NodeOutcome{
			Status:  statusUnknown,
			Verdict: unknownVerdict,
			Summary: "threshold field is not numeric: " + field,
			Value:   unknownVerdict,
			Payload: map[string]any{"passed": false, "field": field, "verdict": unknownVerdict},
		}
	}

	direction := strings.ToLower(firstNonEmptyString(node.Config["direction"], "above"))
	critVal, hasCrit := floatFromAny(firstNonNil(node.Config["critical"], node.Config["crit"]))
	warnVal, hasWarn := floatFromAny(firstNonNil(node.Config["warning"], node.Config["warn"]))

	breached := func(val, limit float64) bool {
		if direction == "below" || direction == "lt" || direction == "lte" {
			return val < limit
		}
		return val > limit
	}

	if hasCrit && breached(actualNum, critVal) {
		return NodeOutcome{
			Status:  statusDown,
			Verdict: critVerdict,
			Summary: fmt.Sprintf("%s %.2f breached critical threshold %.2f", field, actualNum, critVal),
			Value:   valueToString(actualNum),
			Payload: map[string]any{"passed": false, "field": field, "actual": actualNum, "verdict": critVerdict},
		}
	}
	if hasWarn && breached(actualNum, warnVal) {
		return NodeOutcome{
			Status:  statusDegraded,
			Verdict: warnVerdict,
			Summary: fmt.Sprintf("%s %.2f breached warning threshold %.2f", field, actualNum, warnVal),
			Value:   valueToString(actualNum),
			Payload: map[string]any{"passed": false, "field": field, "actual": actualNum, "verdict": warnVerdict},
		}
	}

	return NodeOutcome{
		Status:  statusHealthy,
		Verdict: passVerdict,
		Summary: fmt.Sprintf("%s %.2f within threshold", field, actualNum),
		Value:   valueToString(actualNum),
		Payload: map[string]any{"passed": true, "field": field, "actual": actualNum, "verdict": passVerdict},
	}
}

func evalDecisionTableNode(node NodeSpec, edges []EdgeSpec, outcomeByID map[string]NodeOutcome) NodeOutcome {
	combine := strings.ToLower(firstNonEmptyString(node.Config["combine"], "first_match"))
	defaultVerdict := firstNonEmptyString(node.Config["default_verdict"], statusUnknown)
	severityMap := map[string]string{}
	if rawSev, ok := node.Config["verdict_severity"].(map[string]any); ok {
		for k, v := range rawSev {
			severityMap[k] = normalizeStatusString(valueToString(v))
		}
	}

	byHandle := map[string]NodeOutcome{}
	for k, v := range outcomeByID {
		byHandle[k] = v
	}
	for _, e := range edges {
		if e.effectiveTo() == node.ID {
			if out, exists := outcomeByID[e.effectiveFrom()]; exists {
				if e.TargetHandle != "" {
					byHandle[e.TargetHandle] = out
					byHandle[strings.TrimPrefix(e.TargetHandle, "in:")] = out
				}
			}
		}
	}

	signalStates := map[string]string{}
	for nodeID, out := range outcomeByID {
		signalStates[nodeID] = out.Status
	}
	for _, inCfg := range sliceOfMaps(node.Config["inputs"]) {
		alias := firstNonEmptyString(inCfg["key"], inCfg["id"], inCfg["name"], inCfg["alias"])
		fromNode := firstNonEmptyString(inCfg["source_node_id"], inCfg["source_node"], inCfg["node_id"], inCfg["from"], alias)
		field := stringFromAny(inCfg["field"])
		if alias == "" {
			continue
		}
		out, exists := byHandle[alias]
		if !exists && fromNode != "" {
			out, exists = byHandle[fromNode]
		}
		if !exists {
			signalStates[alias] = statusUnknown
			continue
		}
		if field != "" {
			signalStates[alias] = extractDecisionOutcomeField(out, field)
		} else if _, hasKey := inCfg["key"]; hasKey && out.Value != "" {
			signalStates[alias] = out.Value
		} else {
			signalStates[alias] = out.Status
		}
	}

	verdictToStatus := func(verdict, explicitStatus string) string {
		if explicitStatus != "" {
			return normalizeStatusString(explicitStatus)
		}
		if mapped, ok := severityMap[verdict]; ok {
			return mapped
		}
		return normalizeStatusString(verdict)
	}

	rules := sliceOfMaps(node.Config["rules"])
	type matchedRule struct {
		verdict string
		status  string
		summary string
	}
	var matched []matchedRule

	for _, rule := range rules {
		condMap, ok := rule["match"].(map[string]any)
		if !ok {
			condMap, _ = rule["when"].(map[string]any)
		}
		if matchesDecisionWhen(condMap, signalStates) {
			v := firstNonEmptyString(rule["verdict"], rule["status"], statusHealthy)
			st := verdictToStatus(v, stringFromAny(rule["status"]))
			s := firstNonEmptyString(rule["summary"], rule["description"], rule["label"], "matched decision rule: "+v)
			matched = append(matched, matchedRule{verdict: v, status: st, summary: s})
			if combine == "first_match" {
				break
			}
		}
	}

	chosenVerdict := defaultVerdict
	chosenStatus := verdictToStatus(defaultVerdict, "")
	chosenSummary := "default verdict: " + defaultVerdict
	if len(matched) > 0 {
		chosenVerdict = matched[0].verdict
		chosenStatus = matched[0].status
		chosenSummary = matched[0].summary
		if combine == "worst_of" {
			worstRank := statusSeverityRank(chosenStatus)
			for i := 1; i < len(matched); i++ {
				r := statusSeverityRank(matched[i].status)
				if r > worstRank {
					worstRank = r
					chosenVerdict = matched[i].verdict
					chosenStatus = matched[i].status
					chosenSummary = matched[i].summary
				}
			}
		}
	}

	return NodeOutcome{
		Status:  chosenStatus,
		Verdict: chosenVerdict,
		Summary: chosenSummary,
		Value:   chosenVerdict,
		Payload: map[string]any{
			"verdict": chosenVerdict,
			"status":  chosenStatus,
			"signals": signalStates,
		},
	}
}

func extractDecisionOutcomeField(out NodeOutcome, field string) string {
	switch field {
	case "status":
		if out.Status != "" {
			return out.Status
		}
	case "verdict":
		if out.Verdict != "" {
			return out.Verdict
		}
	case "value":
		if out.Value != "" {
			return out.Value
		}
	}
	if out.Payload != nil {
		if v, ok := out.Payload[field]; ok && v != nil {
			return valueToString(v)
		}
		if strings.Contains(field, ".") {
			if v, ok := lookupJSONPath(out.Payload, "$."+field); ok && v != nil {
				return valueToString(v)
			}
		}
	}
	return statusUnknown
}

func evalAlertOutputNode(node NodeSpec, upstreams []NodeOutcome, ctx *evalContext) NodeOutcome {
	status := statusHealthy
	verdict := statusHealthy
	summary := "check healthy"
	if len(upstreams) > 0 {
		worst := upstreams[0]
		for i := 1; i < len(upstreams); i++ {
			if statusSeverityRank(upstreams[i].Status) > statusSeverityRank(worst.Status) {
				worst = upstreams[i]
			}
		}
		status = worst.Status
		verdict = worst.Verdict
		if worst.Summary != "" {
			summary = worst.Summary
		}
	}
	if vmap, ok := node.Config["verdict_map"].(map[string]any); ok {
		if mapped := stringFromAny(vmap[status]); mapped != "" {
			verdict = mapped
		}
	}
	if tpl := stringFromAny(node.Config["summary_template"]); tpl != "" {
		replaced := strings.ReplaceAll(tpl, "{{verdict}}", verdict)
		replaced = strings.ReplaceAll(replaced, "{{status}}", status)
		if rendered, err := ctx.interpolate(replaced, interpModeRaw); err == nil && rendered != "" {
			summary = ctx.scrubString(rendered)
		} else {
			summary = ctx.scrubString(replaced)
		}
	}
	return NodeOutcome{
		Status:  status,
		Verdict: verdict,
		Summary: summary,
		Value:   verdict,
		Payload: map[string]any{
			"verdict": verdict,
			"status":  status,
			"summary": summary,
		},
	}
}

func matchesDecisionWhen(whenMap map[string]any, signals map[string]string) bool {
	if len(whenMap) == 0 {
		return true
	}
	for sig, expected := range whenMap {
		actual, exists := signals[sig]
		if !exists {
			actual = statusUnknown
		}
		switch typed := expected.(type) {
		case string:
			if typed == "*" || strings.EqualFold(typed, "any") {
				continue
			}
			if !strings.EqualFold(actual, typed) {
				return false
			}
		case []any:
			matched := false
			for _, item := range typed {
				s := valueToString(item)
				if s == "*" || strings.EqualFold(actual, s) {
					matched = true
					break
				}
			}
			if !matched {
				return false
			}
		default:
			if !strings.EqualFold(actual, valueToString(expected)) {
				return false
			}
		}
	}
	return true
}

func lookupJSONPath(doc any, rawPath string) (any, bool) {
	path := strings.TrimSpace(rawPath)
	path = strings.TrimPrefix(path, "$")
	path = strings.TrimPrefix(path, ".")
	if path == "" {
		return doc, doc != nil
	}

	tokens := tokenizeJSONPath(path)
	cur := doc
	for _, tok := range tokens {
		if cur == nil {
			return nil, false
		}
		if idx, err := strconv.Atoi(tok); err == nil {
			arr, ok := cur.([]any)
			if !ok || idx < 0 || idx >= len(arr) {
				return nil, false
			}
			cur = arr[idx]
			continue
		}
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		next, exists := m[tok]
		if !exists {
			return nil, false
		}
		cur = next
	}
	return cur, true
}

func tokenizeJSONPath(path string) []string {
	var tokens []string
	var buf strings.Builder
	for i := 0; i < len(path); i++ {
		ch := path[i]
		switch ch {
		case '.':
			if buf.Len() > 0 {
				tokens = append(tokens, buf.String())
				buf.Reset()
			}
		case '[':
			if buf.Len() > 0 {
				tokens = append(tokens, buf.String())
				buf.Reset()
			}
		case ']':
			if buf.Len() > 0 {
				tok := strings.Trim(buf.String(), `"'`)
				tokens = append(tokens, tok)
				buf.Reset()
			}
		default:
			buf.WriteByte(ch)
		}
	}
	if buf.Len() > 0 {
		tokens = append(tokens, buf.String())
	}
	return tokens
}

func compareValues(actual any, op string, expected any) bool {
	op = strings.ToLower(strings.TrimSpace(op))
	switch op {
	case "eq", "==":
		if aNum, aOK := floatFromAny(actual); aOK {
			if eNum, eOK := floatFromAny(expected); eOK {
				return aNum == eNum
			}
		}
		return valueToString(actual) == valueToString(expected)
	case "neq", "!=":
		return !compareValues(actual, "eq", expected)
	case "gt", ">":
		aNum, aOK := floatFromAny(actual)
		eNum, eOK := floatFromAny(expected)
		return aOK && eOK && aNum > eNum
	case "gte", ">=":
		aNum, aOK := floatFromAny(actual)
		eNum, eOK := floatFromAny(expected)
		return aOK && eOK && aNum >= eNum
	case "lt", "<":
		aNum, aOK := floatFromAny(actual)
		eNum, eOK := floatFromAny(expected)
		return aOK && eOK && aNum < eNum
	case "lte", "<=":
		aNum, aOK := floatFromAny(actual)
		eNum, eOK := floatFromAny(expected)
		return aOK && eOK && aNum <= eNum
	case "contains":
		switch typed := actual.(type) {
		case []any:
			want := valueToString(expected)
			for _, item := range typed {
				if valueToString(item) == want {
					return true
				}
			}
			return false
		default:
			return strings.Contains(valueToString(actual), valueToString(expected))
		}
	case "in":
		if arr, ok := expected.([]any); ok {
			got := valueToString(actual)
			for _, item := range arr {
				if valueToString(item) == got {
					return true
				}
			}
		}
		return false
	default:
		return false
	}
}

func castExtractedValue(v any, cast string) (any, bool) {
	switch strings.ToLower(strings.TrimSpace(cast)) {
	case "", "any":
		return v, true
	case "string":
		return valueToString(v), true
	case "integer", "int":
		if n, ok := floatFromAny(v); ok {
			return int64(n), true
		}
		return nil, false
	case "number", "float":
		if n, ok := floatFromAny(v); ok {
			return n, true
		}
		return nil, false
	case "boolean", "bool":
		switch typed := v.(type) {
		case bool:
			return typed, true
		case string:
			switch strings.ToLower(strings.TrimSpace(typed)) {
			case "true", "1", "yes":
				return true, true
			case "false", "0", "no":
				return false, true
			}
		}
		return nil, false
	default:
		return v, true
	}
}

func isSensitiveKey(key string) bool {
	k := strings.ToLower(strings.TrimSpace(key))
	if k == "" {
		return false
	}
	for _, token := range []string{
		"authorization",
		"proxy-authorization",
		"cookie",
		"set-cookie",
		"www-authenticate",
		"proxy-authenticate",
		"password",
		"passwd",
		"secret",
		"token",
		"api_key",
		"apikey",
		"x-api-key",
		"private_key",
		"session",
		"jwt",
		"csrf",
	} {
		if strings.Contains(k, token) {
			return true
		}
	}
	return false
}

func scrubCommonAuthTokens(s string) string {
	out := s
	for _, prefix := range []string{"Bearer ", "bearer ", "Basic ", "basic ", "Token ", "token "} {
		searchFrom := 0
		for searchFrom < len(out) {
			relIdx := strings.Index(out[searchFrom:], prefix)
			if relIdx < 0 {
				break
			}
			valStart := searchFrom + relIdx + len(prefix)
			if strings.HasPrefix(out[valStart:], redactedPlaceholder) {
				searchFrom = valStart + len(redactedPlaceholder)
				continue
			}
			valEnd := valStart
			for valEnd < len(out) {
				ch := out[valEnd]
				if ch == ' ' || ch == '"' || ch == '\'' || ch == ',' || ch == ';' || ch == '\r' || ch == '\n' || ch == '}' || ch == ']' {
					break
				}
				valEnd++
			}
			if valEnd == valStart {
				searchFrom = valStart
				continue
			}
			out = out[:valStart] + redactedPlaceholder + out[valEnd:]
			searchFrom = valStart + len(redactedPlaceholder)
		}
	}
	return out
}

func boundSnapshotsMap(snapshots map[string]any) map[string]any {
	encoded, err := json.Marshal(snapshots)
	if err == nil && len(encoded) <= maxSnapshotBytes {
		return snapshots
	}
	keys := make([]string, 0, len(snapshots))
	for k := range snapshots {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	slim := make(map[string]any, len(keys))
	for _, k := range keys {
		if nodeMap, ok := snapshots[k].(map[string]any); ok {
			slim[k] = map[string]any{
				"status":    nodeMap["status"],
				"verdict":   nodeMap["verdict"],
				"summary":   boundedPreview(stringFromAny(nodeMap["summary"]), 160),
				"truncated": true,
			}
		}
	}
	if slimBytes, sErr := json.Marshal(slim); sErr == nil && len(slimBytes) <= maxSnapshotBytes {
		return slim
	}
	return map[string]any{"_truncated": true}
}

func boundSinglePayload(payload map[string]any) map[string]any {
	if payload == nil {
		return map[string]any{}
	}
	encoded, err := json.Marshal(payload)
	if err == nil && len(encoded) <= maxSnapshotBytes {
		return payload
	}
	slim := map[string]any{
		"truncated":    true,
		"probe_failed": boolFromAny(payload["probe_failed"], false),
	}
	if lat, ok := payload["latency_ms"]; ok {
		slim["latency_ms"] = lat
	}
	if sc, ok := payload["status_code"]; ok {
		slim["status_code"] = sc
	}
	return slim
}

func normalizeStatusString(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "healthy", "ok", "up", "compliant", "passed":
		return statusHealthy
	case "degraded", "warning", "warn":
		return statusDegraded
	case "down", "critical", "crit", "failed", "non_compliant", "error":
		return statusDown
	default:
		return statusUnknown
	}
}

func statusSeverityRank(s string) int {
	switch normalizeStatusString(s) {
	case statusDown:
		return 3
	case statusDegraded:
		return 2
	case statusUnknown:
		return 1
	default:
		return 0
	}
}

func statusToPluginStatus(s string) string {
	switch normalizeStatusString(s) {
	case statusHealthy:
		return "OK"
	case statusDegraded:
		return "WARNING"
	case statusDown:
		return "CRITICAL"
	default:
		return "UNKNOWN"
	}
}

func boundedPreview(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	return s[:maxBytes] + "...[truncated]"
}

func roundMS(v float64) float64 {
	return math.Round(v*100) / 100
}

func stringFromAny(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func firstNonEmptyString(vals ...any) string {
	for _, v := range vals {
		if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
			return s
		}
	}
	return ""
}

func firstNonNil(vals ...any) any {
	for _, v := range vals {
		if v != nil {
			return v
		}
	}
	return nil
}

func valueToString(v any) string {
	switch typed := v.(type) {
	case nil:
		return ""
	case string:
		return typed
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	case float64:
		if typed == math.Trunc(typed) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case json.Number:
		return typed.String()
	default:
		b, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprint(typed)
		}
		return string(b)
	}
}

func floatFromAny(v any) (float64, bool) {
	switch typed := v.(type) {
	case float64:
		return typed, true
	case float32:
		return float64(typed), true
	case int:
		return float64(typed), true
	case int64:
		return float64(typed), true
	case json.Number:
		f, err := typed.Float64()
		return f, err == nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(typed), 64)
		return f, err == nil
	default:
		return 0, false
	}
}

func intFromAny(v any, def int) int {
	if f, ok := floatFromAny(v); ok {
		return int(f)
	}
	return def
}

func boolFromAny(v any, def bool) bool {
	switch typed := v.(type) {
	case bool:
		return typed
	case string:
		switch strings.ToLower(strings.TrimSpace(typed)) {
		case "true", "1", "yes":
			return true
		case "false", "0", "no":
			return false
		}
	}
	return def
}

func sliceOfMaps(v any) []map[string]any {
	switch typed := v.(type) {
	case []map[string]any:
		return typed
	case []any:
		out := make([]map[string]any, 0, len(typed))
		for _, item := range typed {
			if m, ok := item.(map[string]any); ok {
				out = append(out, m)
			}
		}
		return out
	default:
		return nil
	}
}

func stringSliceFromAny(v any) []string {
	switch typed := v.(type) {
	case []string:
		return typed
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if s := strings.TrimSpace(valueToString(item)); s != "" {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

func foldedContains(items []string, candidate string) bool {
	for _, item := range items {
		if strings.EqualFold(strings.TrimSpace(item), strings.TrimSpace(candidate)) {
			return true
		}
	}
	return false
}

func intSliceContains(items []int, candidate int) bool {
	for _, item := range items {
		if item == candidate {
			return true
		}
	}
	return false
}
