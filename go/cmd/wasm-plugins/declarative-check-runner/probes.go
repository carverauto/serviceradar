package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxRedirects      = 5
	maxBodyPreviewLen = 1024
	maxDNSWireBytes   = 65535
)

type httpStepSpec struct {
	ID                 string
	Method             string
	URL                string
	Headers            map[string]string
	Body               string
	CredentialSlot     string
	TimeoutMS          int
	InsecureSkipVerify bool
	FollowRedirects    bool
	ExpectedStatus     int
	ExpectedStatuses   []int
	ExpectedHeaders    map[string]string
	BodyContains       string
	BodyRegex          string
	JSONAssertions     []map[string]any
	Extractions        []stepExtractionSpec
}

type stepExtractionSpec struct {
	Name    string
	From    string
	Path    string
	Header  string
	Pattern string
	Secret  bool
}

func evalHTTPRequestNode(
	node NodeSpec,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
) (NodeOutcome, []metricSample) {
	step := parseHTTPStepSpec(node.ID, node.Config, cfg.TimeoutMS)
	stepRes, samples, err := executeHTTPStep(step, node.ID, "http_request", cfg, target, ctx, deps, false)
	if err != nil {
		reason := ctx.scrubString(err.Error())
		return NodeOutcome{
			Status:  statusDown,
			Verdict: statusDown,
			Summary: reason,
			Value:   statusDown,
			Payload: map[string]any{
				"probe_failed":   true,
				"latency_ms":     stepRes.LatencyMS,
				"failure_reason": reason,
			},
			DurationMS: int64(stepRes.LatencyMS),
		}, samples
	}

	status := statusHealthy
	summary := fmt.Sprintf("HTTP %d in %.2fms", stepRes.StatusCode, stepRes.LatencyMS)
	if !stepRes.AssertionsPassed {
		status = statusDown
		summary = stepRes.FailureReason
	}

	payload := map[string]any{
		"status_code":       stepRes.StatusCode,
		"latency_ms":        stepRes.LatencyMS,
		"probe_failed":      false,
		"assertions_passed": stepRes.AssertionsPassed,
		"headers":           stepRes.RedactedHeaders,
		"body":              stepRes.BodyPreview,
		"timings":           stepRes.TimingsMap(),
	}
	if stepRes.FailureReason != "" {
		payload["failure_reason"] = stepRes.FailureReason
	}

	return NodeOutcome{
		Status:     status,
		Verdict:    status,
		Summary:    summary,
		Value:      itoa(stepRes.StatusCode),
		Payload:    payload,
		DurationMS: int64(stepRes.LatencyMS),
	}, samples
}

func evalHTTPJourneyNode(
	node NodeSpec,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
) (NodeOutcome, []metricSample) {
	rawSteps := sliceOfMaps(node.Config["steps"])
	if len(rawSteps) == 0 {
		return NodeOutcome{
			Status:  statusUnknown,
			Verdict: statusUnknown,
			Summary: "http_journey has no steps configured",
			Value:   statusUnknown,
			Payload: map[string]any{
				"probe_failed": true,
				"latency_ms":   0.0,
			},
		}, nil
	}

	var (
		allSamples  []metricSample
		stepRecords = make([]map[string]any, 0, len(rawSteps))
		totalMS     float64
		finalStatus = statusHealthy
		summary     string
		probeFailed bool
		failedStep  string
	)

	for idx, rawStep := range rawSteps {
		defaultID := fmt.Sprintf("step_%d", idx+1)
		step := parseHTTPStepSpec(defaultID, rawStep, cfg.TimeoutMS)
		stepRes, stepSamples, err := executeHTTPStep(step, node.ID, "http_journey", cfg, target, ctx, deps, true)
		allSamples = append(allSamples, stepSamples...)
		totalMS += stepRes.LatencyMS

		record := map[string]any{
			"step_id":           step.ID,
			"status_code":       stepRes.StatusCode,
			"latency_ms":        stepRes.LatencyMS,
			"assertions_passed": stepRes.AssertionsPassed && err == nil,
			"headers":           stepRes.RedactedHeaders,
			"timings":           stepRes.TimingsMap(),
		}
		if len(stepRes.ExtractedPublic) > 0 {
			record["extracted"] = stepRes.ExtractedPublic
		}
		if err != nil {
			reason := ctx.scrubString(err.Error())
			record["failure_reason"] = reason
			record["probe_failed"] = true
			stepRecords = append(stepRecords, record)
			finalStatus = statusDown
			probeFailed = true
			failedStep = step.ID
			summary = fmt.Sprintf("step %s failed: %s", step.ID, reason)
			break
		}
		if !stepRes.AssertionsPassed {
			record["failure_reason"] = stepRes.FailureReason
			record["probe_failed"] = false
			stepRecords = append(stepRecords, record)
			finalStatus = statusDown
			failedStep = step.ID
			summary = fmt.Sprintf("step %s assertion failed: %s", step.ID, stepRes.FailureReason)
			break
		}
		stepRecords = append(stepRecords, record)
	}

	totalMS = roundMS(totalMS)
	baseTags := baseMetricTags(cfg, target, node.ID, "http_journey")
	allSamples = append(allSamples, metricSample{
		Name:  "declarative_check.http_journey.duration_ms",
		Unit:  "ms",
		Value: totalMS,
		Tags:  baseTags,
	})

	if summary == "" {
		summary = fmt.Sprintf("all %d journey steps passed in %.2fms", len(stepRecords), totalMS)
	}

	payload := map[string]any{
		"steps_completed": len(stepRecords),
		"steps_total":     len(rawSteps),
		"latency_ms":      totalMS,
		"probe_failed":    probeFailed,
		"steps":           stepRecords,
	}
	if failedStep != "" {
		payload["failed_step"] = failedStep
	}

	return NodeOutcome{
		Status:     finalStatus,
		Verdict:    finalStatus,
		Summary:    ctx.scrubString(summary),
		Value:      finalStatus,
		Payload:    ctx.scrubMap(payload),
		DurationMS: int64(totalMS),
	}, allSamples
}

type stepExecResult struct {
	StatusCode       int
	LatencyMS        float64
	Trace            *hostHTTPTrace
	RedactedHeaders  map[string]string
	BodyPreview      string
	AssertionsPassed bool
	FailureReason    string
	ExtractedPublic  map[string]any
}

func (r stepExecResult) TimingsMap() map[string]any {
	out := map[string]any{
		"total_ms": r.LatencyMS,
	}
	if r.Trace != nil {
		if r.Trace.DNSMS > 0 {
			out["dns_ms"] = r.Trace.DNSMS
		}
		if r.Trace.TCPMS > 0 {
			out["tcp_ms"] = r.Trace.TCPMS
		}
		if r.Trace.TLSMS > 0 {
			out["tls_ms"] = r.Trace.TLSMS
		}
		if r.Trace.TTFBMS > 0 {
			out["ttfb_ms"] = r.Trace.TTFBMS
		}
		if r.Trace.TransferMS > 0 {
			out["transfer_ms"] = r.Trace.TransferMS
		}
		if r.Trace.TotalMS > 0 {
			out["total_ms"] = r.Trace.TotalMS
		}
	}
	return out
}

func executeHTTPStep(
	step httpStepSpec,
	nodeID string,
	nodeType string,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
	isJourney bool,
) (stepExecResult, []metricSample, error) {
	var res stepExecResult

	resolvedURL, err := ctx.interpolate(step.URL, interpModeURL)
	if err != nil {
		return res, nil, err
	}
	if strings.TrimSpace(resolvedURL) == "" {
		return res, nil, sentinelError("http probe missing url")
	}

	parsedURL, err := url.Parse(resolvedURL)
	if err != nil || parsedURL.Host == "" {
		return res, nil, sentinelError("http probe has invalid url")
	}
	if err := cfg.Allowlist.checkURL(parsedURL); err != nil {
		return res, nil, err
	}

	headers := make(map[string]string, len(step.Headers))
	for k, v := range step.Headers {
		interpVal, interpErr := ctx.interpolate(v, interpModeHeader)
		if interpErr != nil {
			return res, nil, interpErr
		}
		headers[k] = interpVal
		if isSensitiveKey(k) && interpVal != "" {
			ctx.markSecret(interpVal)
		}
	}

	bodyStr, err := ctx.interpolate(step.Body, interpModeRaw)
	if err != nil {
		return res, nil, err
	}

	credInject, err := resolveCredentialInjection(step.CredentialSlot, step.Method, parsedURL, cfg, target, deps.Now())
	if err != nil {
		return res, nil, err
	}

	currentURL := parsedURL
	currentMethod := step.Method
	currentBody := []byte(bodyStr)
	currentHeaders := headers
	currentCred := credInject

	var (
		lastResp *hostHTTPResp
		totalDur time.Duration
	)

	for hop := 0; hop <= maxRedirects; hop++ {
		resp, reqErr := deps.HTTPDo(hostHTTPReq{
			Method:              currentMethod,
			URL:                 currentURL.String(),
			Headers:             currentHeaders,
			Body:                currentBody,
			TimeoutMS:           step.TimeoutMS,
			InsecureSkipVerify:  step.InsecureSkipVerify,
			CredentialInjection: currentCred,
		})
		if reqErr != nil {
			res.LatencyMS = durationMS(totalDur)
			return res, nil, reqErr
		}
		totalDur += resp.Duration
		lastResp = resp

		if !step.FollowRedirects || !isRedirectStatus(resp.Status) {
			break
		}
		loc := headerCaseInsensitive(resp.Headers, "Location")
		if strings.TrimSpace(loc) == "" {
			break
		}
		if hop == maxRedirects {
			res.LatencyMS = durationMS(totalDur)
			return res, nil, sentinelError("stopped after maximum redirects")
		}
		nextURL, parseErr := currentURL.Parse(strings.TrimSpace(loc))
		if parseErr != nil || nextURL.Host == "" {
			res.LatencyMS = durationMS(totalDur)
			return res, nil, sentinelError("invalid redirect location")
		}
		if allowErr := cfg.Allowlist.checkURL(nextURL); allowErr != nil {
			res.LatencyMS = durationMS(totalDur)
			return res, nil, sentinelError("redirect destination blocked by allowlist")
		}

		sameOrigin := strings.EqualFold(currentURL.Scheme, nextURL.Scheme) &&
			strings.EqualFold(currentURL.Host, nextURL.Host)
		if !sameOrigin {
			currentHeaders = stripSensitiveRedirectHeaders(currentHeaders)
			currentCred = nil
		} else if currentCred != nil {
			rechecked, credErr := resolveCredentialInjection(step.CredentialSlot, currentMethod, nextURL, cfg, target, deps.Now())
			if credErr != nil {
				currentCred = nil
			} else {
				currentCred = rechecked
			}
		}
		if resp.Status == http.StatusSeeOther || ((resp.Status == http.StatusMovedPermanently || resp.Status == http.StatusFound) && currentMethod == http.MethodPost) {
			currentMethod = http.MethodGet
			currentBody = nil
		}
		currentURL = nextURL
	}

	latencyMS := durationMS(totalDur)
	if lastResp.Trace != nil && lastResp.Trace.TotalMS > 0 && latencyMS == 0 {
		latencyMS = lastResp.Trace.TotalMS
	}
	res.StatusCode = lastResp.Status
	res.LatencyMS = latencyMS
	res.Trace = lastResp.Trace

	var parsedJSON any
	hasJSON := false
	if len(lastResp.Body) > 0 {
		if json.Unmarshal(lastResp.Body, &parsedJSON) == nil {
			hasJSON = true
		}
	}

	extractedPublic := map[string]any{}
	for _, ex := range step.Extractions {
		val, ok := extractFromHTTPResponse(ex, lastResp, parsedJSON, hasJSON)
		if !ok {
			continue
		}
		isSecret := ex.Secret || isSensitiveKey(ex.Name) || isSensitiveKey(ex.Header)
		strVal := valueToString(val)
		if isSecret && strVal != "" {
			ctx.markSecret(strVal)
			extractedPublic[ex.Name] = redactedPlaceholder
		} else {
			extractedPublic[ex.Name] = val
		}
		ctx.setStepVar(step.ID, ex.Name, val)
	}
	res.ExtractedPublic = extractedPublic

	okAssert, failReason := evaluateHTTPAssertions(step, lastResp, parsedJSON, hasJSON)
	res.AssertionsPassed = okAssert
	res.FailureReason = ctx.scrubString(failReason)
	res.RedactedHeaders = redactHTTPHeaders(lastResp.Headers, ctx)
	res.BodyPreview = boundedPreview(ctx.scrubString(string(lastResp.Body)), maxBodyPreviewLen)

	metricPrefix := "declarative_check.http"
	tags := baseMetricTags(cfg, target, nodeID, nodeType)
	if isJourney {
		metricPrefix = "declarative_check.http_journey.step"
		tags = cloneTagsWith(tags, "step_id", step.ID)
	}
	samples := []metricSample{
		{Name: metricPrefix + ".duration_ms", Unit: "ms", Value: latencyMS, Tags: tags},
		{Name: metricPrefix + ".status_code", Unit: "count", Value: float64(lastResp.Status), Tags: tags},
	}
	samples = appendHTTPTraceMetrics(samples, metricPrefix, tags, lastResp.Trace)

	return res, samples, nil
}

func evaluateHTTPAssertions(step httpStepSpec, resp *hostHTTPResp, parsedJSON any, hasJSON bool) (bool, string) {
	if len(step.ExpectedStatuses) > 0 {
		matched := false
		for _, code := range step.ExpectedStatuses {
			if resp.Status == code {
				matched = true
				break
			}
		}
		if !matched {
			return false, fmt.Sprintf("expected status in %v, got %d", step.ExpectedStatuses, resp.Status)
		}
	} else if step.ExpectedStatus > 0 {
		if resp.Status != step.ExpectedStatus {
			return false, fmt.Sprintf("expected status %d, got %d", step.ExpectedStatus, resp.Status)
		}
	} else if resp.Status < 200 || resp.Status >= 300 {
		return false, fmt.Sprintf("expected 2xx status, got %d", resp.Status)
	}

	for hdr, expected := range step.ExpectedHeaders {
		actual := headerCaseInsensitive(resp.Headers, hdr)
		if !strings.Contains(actual, expected) {
			return false, fmt.Sprintf("header %s missing expected value", hdr)
		}
	}

	bodyStr := string(resp.Body)
	if step.BodyContains != "" && !strings.Contains(bodyStr, step.BodyContains) {
		return false, "response body missing expected substring"
	}
	if step.BodyRegex != "" {
		re, err := regexp.Compile(step.BodyRegex)
		if err != nil || !re.MatchString(bodyStr) {
			return false, "response body did not match regex assertion"
		}
	}

	for _, ja := range step.JSONAssertions {
		if !hasJSON {
			return false, "response body is not valid JSON for json_assertions"
		}
		path := stringFromAny(ja["path"])
		op := stringFromAny(ja["op"])
		if op == "" {
			op = "eq"
		}
		expected := ja["value"]
		actual, found := lookupJSONPath(parsedJSON, path)
		if op == "exists" {
			wantExists := true
			if b, ok := expected.(bool); ok {
				wantExists = b
			}
			if found != wantExists {
				return false, fmt.Sprintf("json assertion %s exists=%v failed", path, wantExists)
			}
			continue
		}
		if !found || !compareValues(actual, op, expected) {
			return false, fmt.Sprintf("json assertion %s (%s) failed", path, op)
		}
	}

	return true, ""
}

func extractFromHTTPResponse(ex stepExtractionSpec, resp *hostHTTPResp, parsedJSON any, hasJSON bool) (any, bool) {
	from := strings.ToLower(strings.TrimSpace(ex.From))
	if from == "" {
		switch {
		case ex.Path != "":
			from = "json_path"
		case ex.Header != "":
			from = "header"
		case ex.Pattern != "":
			from = "regex"
		}
	}
	switch from {
	case "json_path", "jsonpath":
		if !hasJSON {
			return nil, false
		}
		return lookupJSONPath(parsedJSON, ex.Path)
	case "header":
		val := headerCaseInsensitive(resp.Headers, ex.Header)
		if val == "" {
			return nil, false
		}
		return val, true
	case "regex":
		re, err := regexp.Compile(ex.Pattern)
		if err != nil {
			return nil, false
		}
		matches := re.FindStringSubmatch(string(resp.Body))
		if len(matches) == 0 {
			return nil, false
		}
		if len(matches) > 1 {
			return matches[1], true
		}
		return matches[0], true
	case "status_code":
		return resp.Status, true
	default:
		return nil, false
	}
}

func evalTCPConnectNode(
	node NodeSpec,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
) (NodeOutcome, []metricSample) {
	hostTemplate := stringFromAny(node.Config["host"])
	if hostTemplate == "" {
		hostTemplate = "${target.host}"
	}
	host, err := ctx.interpolate(hostTemplate, interpModeHost)
	if err != nil || strings.TrimSpace(host) == "" {
		return probeFailureOutcome("tcp_connect missing valid target host", 0), nil
	}
	port := intFromAny(node.Config["port"], target.Port)
	if port < 1 || port > 65535 {
		return probeFailureOutcome("tcp_connect missing valid port", 0), nil
	}
	if err := cfg.Allowlist.checkHostPort(host, port); err != nil {
		return probeFailureOutcome(err.Error(), 0), nil
	}

	timeoutMS := intFromAny(node.Config["timeout_ms"], cfg.TimeoutMS)
	if timeoutMS <= 0 {
		timeoutMS = 5000
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond

	start := time.Now()
	conn, err := deps.TCPDial(host, uint16(port), timeout)
	latency := durationMS(time.Since(start))
	tags := baseMetricTags(cfg, target, node.ID, "tcp_connect")

	if err != nil {
		reason := ctx.scrubString(fmt.Sprintf("tcp connect failed: %v", err))
		return NodeOutcome{
			Status:  statusDown,
			Verdict: statusDown,
			Summary: reason,
			Value:   statusDown,
			Payload: map[string]any{
				"connected":      false,
				"probe_failed":   true,
				"host":           host,
				"port":           port,
				"latency_ms":     latency,
				"failure_reason": reason,
			},
			DurationMS: int64(latency),
		}, nil
	}
	defer func() { _ = conn.Close() }()

	sendBanner := stringFromAny(node.Config["send"])
	expectBanner := stringFromAny(node.Config["expect"])
	bannerMatched := true
	if sendBanner != "" || expectBanner != "" {
		_ = conn.SetDeadline(time.Now().Add(timeout))
		if sendBanner != "" {
			if _, wErr := conn.Write([]byte(sendBanner)); wErr != nil {
				bannerMatched = false
			}
		}
		if bannerMatched && expectBanner != "" {
			buf := make([]byte, 512)
			n, rErr := conn.Read(buf)
			if rErr != nil && n == 0 {
				bannerMatched = false
			} else if !strings.Contains(string(buf[:n]), expectBanner) {
				bannerMatched = false
			}
		}
		latency = durationMS(time.Since(start))
	}

	samples := []metricSample{
		{Name: "declarative_check.tcp.connect_ms", Unit: "ms", Value: latency, Tags: tags},
	}

	status := statusHealthy
	summary := fmt.Sprintf("TCP %s:%d connected in %.2fms", host, port, latency)
	if !bannerMatched {
		status = statusDown
		summary = fmt.Sprintf("TCP %s:%d banner expectation failed", host, port)
	} else if maxMS, hasMax := floatFromAny(node.Config["max_latency_ms"]); hasMax && latency > maxMS {
		status = statusDown
		summary = fmt.Sprintf("TCP latency %.2fms exceeded max %.2fms", latency, maxMS)
	} else if warnMS, hasWarn := floatFromAny(node.Config["warn_latency_ms"]); hasWarn && latency > warnMS {
		status = statusDegraded
		summary = fmt.Sprintf("TCP latency %.2fms exceeded warn %.2fms", latency, warnMS)
	}

	return NodeOutcome{
		Status:  status,
		Verdict: status,
		Summary: summary,
		Value:   fmt.Sprintf("%.2f", latency),
		Payload: map[string]any{
			"connected":    true,
			"probe_failed": false,
			"host":         host,
			"port":         port,
			"latency_ms":   latency,
		},
		DurationMS: int64(latency),
	}, samples
}

func evalTLSHandshakeNode(
	node NodeSpec,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
) (NodeOutcome, []metricSample) {
	hostTemplate := stringFromAny(node.Config["host"])
	if hostTemplate == "" {
		hostTemplate = "${target.host}"
	}
	host, err := ctx.interpolate(hostTemplate, interpModeHost)
	if err != nil || strings.TrimSpace(host) == "" {
		return probeFailureOutcome("tls_handshake missing valid target host", 0), nil
	}
	port := intFromAny(node.Config["port"], target.Port)
	if port <= 0 {
		port = 443
	}
	if err := cfg.Allowlist.checkHostPort(host, port); err != nil {
		return probeFailureOutcome(err.Error(), 0), nil
	}

	sniTemplate := stringFromAny(node.Config["server_name"])
	if sniTemplate == "" {
		sniTemplate = stringFromAny(node.Config["sni"])
	}
	sni := host
	if sniTemplate != "" {
		if resolvedSNI, sniErr := ctx.interpolate(sniTemplate, interpModeHost); sniErr == nil && resolvedSNI != "" {
			sni = resolvedSNI
		}
	}

	timeoutMS := intFromAny(node.Config["timeout_ms"], cfg.TimeoutMS)
	if timeoutMS <= 0 {
		timeoutMS = 5000
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond
	insecureSkipVerify := boolFromAny(node.Config["insecure_skip_verify"], false)
	caBundlePEM := stringFromAny(node.Config["ca_bundle_pem"])

	start := time.Now()
	rawConn, err := deps.TCPDial(host, uint16(port), timeout)
	if err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome(ctx.scrubString(fmt.Sprintf("tls tcp dial failed: %v", err)), latency), nil
	}
	defer func() { _ = rawConn.Close() }()
	_ = rawConn.SetDeadline(time.Now().Add(timeout))

	var roots []*parsedX509Cert
	if caBundlePEM != "" && !insecureSkipVerify {
		parsedRoots, parseErr := parsePEMCertificates([]byte(caBundlePEM))
		if parseErr != nil {
			return probeFailureOutcome("tls_handshake invalid ca_bundle_pem", 0), nil
		}
		roots = parsedRoots
	}

	hsInfo, err := performTLSClientHandshake(rawConn, sni)
	if err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome(ctx.scrubString(fmt.Sprintf("tls handshake failed: %v", err)), latency), nil
	}

	latency := durationMS(time.Since(start))
	if len(hsInfo.PeerCertificates) == 0 {
		return probeFailureOutcome("tls peer presented no certificates", latency), nil
	}

	leaf := hsInfo.PeerCertificates[0]
	now := deps.Now()
	if !insecureSkipVerify {
		if len(roots) > 0 {
			if verifyErr := verifyCertChainAgainstRoots(hsInfo.PeerCertificates, roots, sni, now); verifyErr != nil {
				return probeFailureOutcome("tls certificate verification failed: "+verifyErr.Error(), latency), nil
			}
		} else {
			if now.Before(leaf.NotBefore) {
				return probeFailureOutcome("tls leaf certificate is not yet valid", latency), nil
			}
			if !now.Before(leaf.NotAfter) {
				return probeFailureOutcome("tls leaf certificate has expired", latency), nil
			}
			if sni != "" {
				if verifyErr := leaf.verifyHostname(sni); verifyErr != nil {
					return probeFailureOutcome("tls certificate hostname verification failed", latency), nil
				}
			}
		}
	}

	leafDays := math.Floor(leaf.NotAfter.Sub(now).Hours()/24.0*100) / 100
	tlsVer := formatTLSVersion(hsInfo.Version)
	cipherName := tlsCipherSuiteName(hsInfo.CipherSuite)

	tags := baseMetricTags(cfg, target, node.ID, "tls_handshake")
	samples := []metricSample{
		{Name: "declarative_check.tls.handshake_ms", Unit: "ms", Value: latency, Tags: tags},
		{Name: "declarative_check.tls.leaf_days_remaining", Unit: "days", Value: leafDays, Tags: tags},
	}

	status := statusHealthy
	summary := fmt.Sprintf("TLS %s (%s), %.1f days remaining", tlsVer, cipherName, leafDays)

	if expectedVer := strings.TrimSpace(stringFromAny(node.Config["expected_tls_version"])); expectedVer != "" && !strings.EqualFold(expectedVer, tlsVer) {
		status = statusDown
		summary = fmt.Sprintf("expected TLS version %s, negotiated %s", expectedVer, tlsVer)
	} else if minVer := strings.TrimSpace(stringFromAny(node.Config["min_tls_version"])); minVer != "" && tlsVersionRank(tlsVer) < tlsVersionRank(minVer) {
		status = statusDown
		summary = fmt.Sprintf("negotiated TLS version %s below minimum %s", tlsVer, minVer)
	} else if expectedCipher := strings.TrimSpace(stringFromAny(node.Config["expected_cipher"])); expectedCipher != "" && !strings.EqualFold(expectedCipher, cipherName) {
		status = statusDown
		summary = fmt.Sprintf("expected cipher %s, negotiated %s", expectedCipher, cipherName)
	} else if minDays, hasMin := floatFromAny(node.Config["min_days_remaining"]); hasMin && leafDays < minDays {
		status = statusDown
		summary = fmt.Sprintf("certificate expires in %.1f days (minimum %.1f)", leafDays, minDays)
	} else if warnDays, hasWarn := floatFromAny(node.Config["warn_days_remaining"]); hasWarn && leafDays < warnDays {
		status = statusDegraded
		summary = fmt.Sprintf("certificate expires in %.1f days (warning %.1f)", leafDays, warnDays)
	} else if leafDays <= 0 {
		status = statusDown
		summary = "certificate has expired"
	}

	return NodeOutcome{
		Status:  status,
		Verdict: status,
		Summary: summary,
		Value:   fmt.Sprintf("%.2f", leafDays),
		Payload: map[string]any{
			"probe_failed":        false,
			"latency_ms":          latency,
			"tls_version":         tlsVer,
			"cipher_suite":        cipherName,
			"leaf_days_remaining": leafDays,
			"not_after":           leaf.NotAfter.UTC().Format(time.RFC3339),
			"subject_cn":          leaf.SubjectCN,
			"issuer_cn":           leaf.IssuerCN,
		},
		DurationMS: int64(latency),
	}, samples
}

func evalDNSLookupNode(
	node NodeSpec,
	cfg RunnerConfig,
	target TargetSpec,
	ctx *evalContext,
	deps RunnerDeps,
) (NodeOutcome, []metricSample) {
	qnameTemplate := firstNonEmptyString(node.Config["query_name"], node.Config["hostname"], node.Config["domain"], node.Config["name"], node.Config["host"])
	qname, err := ctx.interpolate(qnameTemplate, interpModeHost)
	if err != nil || strings.TrimSpace(qname) == "" {
		return probeFailureOutcome("dns_lookup missing query_name", 0), nil
	}

	nsRaw := firstNonEmptyString(node.Config["nameserver"], node.Config["server"], "${target.host}")
	nsResolved, err := ctx.interpolate(nsRaw, interpModeRaw)
	if err != nil || strings.TrimSpace(nsResolved) == "" {
		return probeFailureOutcome("dns_lookup missing nameserver", 0), nil
	}

	nsHost := strings.TrimSpace(nsResolved)
	nsPort := intFromAny(node.Config["port"], target.Port)
	if nsPort <= 0 {
		nsPort = 53
	}
	if h, p, ok := splitHostPortOptional(nsHost); ok {
		nsHost = h
		nsPort = p
	}
	if err := cfg.Allowlist.checkHostPort(nsHost, nsPort); err != nil {
		return probeFailureOutcome(err.Error(), 0), nil
	}

	recordType := strings.ToUpper(strings.TrimSpace(firstNonEmptyString(node.Config["record_type"], node.Config["qtype"], "A")))
	qtype := dnsTypeCode(recordType)
	if qtype == 0 {
		return probeFailureOutcome("unsupported dns record_type: "+recordType, 0), nil
	}

	timeoutMS := intFromAny(node.Config["timeout_ms"], cfg.TimeoutMS)
	if timeoutMS <= 0 {
		timeoutMS = 5000
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond

	const txID uint16 = 0x5244
	wireQuery, err := buildDNSWireQuery(txID, qname, qtype)
	if err != nil {
		return probeFailureOutcome(fmt.Sprintf("invalid dns query: %v", err), 0), nil
	}

	start := time.Now()
	conn, err := deps.TCPDial(nsHost, uint16(nsPort), timeout)
	if err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome(ctx.scrubString(fmt.Sprintf("dns tcp connect failed: %v", err)), latency), nil
	}
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	framed := make([]byte, 2+len(wireQuery))
	binary.BigEndian.PutUint16(framed[:2], uint16(len(wireQuery)))
	copy(framed[2:], wireQuery)

	if err := writeAll(conn, framed); err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome("dns query write failed", latency), nil
	}

	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome("dns response header read failed", latency), nil
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen <= 0 || respLen > maxDNSWireBytes {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome("dns response length invalid", latency), nil
	}
	respWire := make([]byte, respLen)
	if _, err := io.ReadFull(conn, respWire); err != nil {
		latency := durationMS(time.Since(start))
		return probeFailureOutcome("dns response body read failed", latency), nil
	}
	latency := durationMS(time.Since(start))

	rcode, answers, parseErr := parseDNSWireResponse(txID, respWire, qtype)
	if parseErr != nil {
		return probeFailureOutcome(fmt.Sprintf("dns response parse error: %v", parseErr), latency), nil
	}

	sort.Strings(answers)
	tags := baseMetricTags(cfg, target, node.ID, "dns_lookup")
	samples := []metricSample{
		{Name: "declarative_check.dns.lookup_ms", Unit: "ms", Value: latency, Tags: tags},
		{Name: "declarative_check.dns.answer_count", Unit: "count", Value: float64(len(answers)), Tags: tags},
	}

	expectedAnswers := stringSliceFromAny(node.Config["expected_answers"])
	requireNonEmpty := boolFromAny(node.Config["require_non_empty"], true)

	status := statusHealthy
	summary := fmt.Sprintf("DNS %s %s resolved %d answer(s) in %.2fms", recordType, qname, len(answers), latency)

	if rcode != 0 {
		status = statusDown
		summary = fmt.Sprintf("DNS %s %s failed with RCODE %d", recordType, qname, rcode)
	} else if requireNonEmpty && len(answers) == 0 {
		status = statusDown
		summary = fmt.Sprintf("DNS %s %s returned zero answers", recordType, qname)
	} else if len(expectedAnswers) > 0 && !containsAllAnswers(answers, expectedAnswers) {
		status = statusDown
		summary = fmt.Sprintf("DNS %s %s missing expected answer", recordType, qname)
	} else if maxMS, hasMax := floatFromAny(node.Config["max_latency_ms"]); hasMax && latency > maxMS {
		status = statusDown
		summary = fmt.Sprintf("DNS lookup %.2fms exceeded max %.2fms", latency, maxMS)
	}

	return NodeOutcome{
		Status:  status,
		Verdict: status,
		Summary: summary,
		Value:   strings.Join(answers, ","),
		Payload: map[string]any{
			"probe_failed": false,
			"query_name":   qname,
			"record_type":  recordType,
			"rcode":        rcode,
			"answers":      answers,
			"latency_ms":   latency,
		},
		DurationMS: int64(latency),
	}, samples
}

func probeFailureOutcome(reason string, latencyMS float64) NodeOutcome {
	return NodeOutcome{
		Status:  statusDown,
		Verdict: statusDown,
		Summary: reason,
		Value:   statusDown,
		Payload: map[string]any{
			"probe_failed":   true,
			"latency_ms":     latencyMS,
			"failure_reason": reason,
		},
		DurationMS: int64(latencyMS),
	}
}

func (a AllowlistSpec) isConfigured() bool {
	return len(a.Schemes) > 0 || len(a.Hosts) > 0 || len(a.Networks) > 0 || len(a.Ports) > 0
}

func (a AllowlistSpec) checkURL(u *url.URL) error {
	if u == nil || u.Host == "" {
		return sentinelError("url missing host")
	}
	scheme := strings.ToLower(strings.TrimSpace(u.Scheme))
	if scheme != "http" && scheme != "https" {
		return sentinelError("unsupported url scheme")
	}
	if len(a.Schemes) > 0 && !foldedContains(a.Schemes, scheme) {
		return sentinelError("scheme blocked by allowlist")
	}
	port := effectiveURLPort(u)
	return a.checkHostPort(u.Hostname(), port)
}

func (a AllowlistSpec) checkHostPort(host string, port int) error {
	host = strings.TrimSuffix(strings.TrimSpace(host), ".")
	if host == "" {
		return sentinelError("empty target host")
	}
	if port < 1 || port > 65535 {
		return sentinelError("invalid target port")
	}
	if !a.isConfigured() {
		return nil
	}
	if len(a.Ports) > 0 && !intSliceContains(a.Ports, port) {
		return sentinelError("port blocked by allowlist")
	}

	if ipBytes, isIP := parseLiteralIP(host); isIP {
		for _, rawNet := range a.Networks {
			if rawNet == "*" || cidrContainsIP(strings.TrimSpace(rawNet), ipBytes) {
				return nil
			}
		}
		for _, allowedHost := range a.Hosts {
			if ah, ok := parseLiteralIP(strings.TrimSuffix(strings.TrimSpace(allowedHost), ".")); ok && equalBytes(ah, ipBytes) {
				return nil
			}
		}
		return sentinelError("ip destination blocked by allowlist")
	}

	lowerHost := strings.ToLower(host)
	for _, pattern := range a.Hosts {
		p := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(pattern), "."))
		if p == "*" || p == lowerHost {
			return nil
		}
		if strings.HasPrefix(p, "*.") {
			base := strings.TrimPrefix(p, "*.")
			if lowerHost == base || strings.HasSuffix(lowerHost, "."+base) {
				return nil
			}
		}
	}
	return sentinelError("host destination blocked by allowlist")
}

func resolveCredentialInjection(
	slot string,
	method string,
	reqURL *url.URL,
	cfg RunnerConfig,
	target TargetSpec,
	now time.Time,
) (*credentialInjectionSpec, error) {
	slot = strings.TrimSpace(slot)
	if slot == "" {
		return nil, nil
	}
	binding, ok := target.CredentialBindings[slot]
	if !ok {
		binding, ok = cfg.CredentialBindings[slot]
	}
	if !ok {
		return nil, sentinelError("missing credential binding for slot: " + slot)
	}

	broker := binding.CredentialBroker
	if broker.ExpiresAt != "" {
		exp, err := time.Parse(time.RFC3339, strings.TrimSpace(broker.ExpiresAt))
		if err != nil || !now.Before(exp) {
			return nil, sentinelError("credential broker grant expired for slot: " + slot)
		}
	}
	if broker.Allow != nil {
		if len(broker.Allow.Schemes) > 0 && !foldedContains(broker.Allow.Schemes, reqURL.Scheme) {
			return nil, sentinelError("credential grant denies scheme")
		}
		if len(broker.Allow.Methods) > 0 && !foldedContains(broker.Allow.Methods, method) {
			return nil, sentinelError("credential grant denies method")
		}
		if len(broker.Allow.Hosts) > 0 && !foldedContains(broker.Allow.Hosts, reqURL.Hostname()) && !foldedContains(broker.Allow.Hosts, reqURL.Host) {
			return nil, sentinelError("credential grant denies host")
		}
		if len(broker.Allow.Ports) > 0 && !intSliceContains(broker.Allow.Ports, effectiveURLPort(reqURL)) {
			return nil, sentinelError("credential grant denies port")
		}
	}

	mode := strings.TrimSpace(binding.Inject.Mode)
	if mode == "" {
		mode = strings.TrimSpace(stringFromAny(broker.Inject["type"]))
	}
	if mode == "" {
		mode = "http_header"
	}
	name := strings.TrimSpace(binding.Inject.Name)
	if name == "" {
		name = strings.TrimSpace(stringFromAny(broker.Inject["name"]))
	}
	scheme := strings.TrimSpace(binding.Inject.Scheme)
	if scheme == "" {
		scheme = strings.TrimSpace(stringFromAny(broker.Inject["scheme"]))
	}
	if mode == "http_header" && name == "" {
		name = "Authorization"
		if scheme == "" {
			scheme = "Bearer"
		}
	}
	secretRef := strings.TrimSpace(binding.SecretRef)
	if secretRef == "" {
		secretRef = strings.TrimSpace(broker.CredentialSecretRef)
	}

	return &credentialInjectionSpec{
		Mode:                mode,
		Name:                name,
		Scheme:              scheme,
		GrantID:             strings.TrimSpace(broker.GrantID),
		CredentialSecretRef: secretRef,
	}, nil
}

func parseHTTPStepSpec(defaultID string, raw map[string]any, defaultTimeoutMS int) httpStepSpec {
	id := firstNonEmptyString(raw["id"], raw["step_id"], raw["name"], defaultID)
	method := strings.ToUpper(strings.TrimSpace(firstNonEmptyString(raw["method"], "GET")))
	timeout := intFromAny(raw["timeout_ms"], defaultTimeoutMS)
	if timeout <= 0 {
		timeout = 10000
	}

	headers := map[string]string{}
	if hMap, ok := raw["headers"].(map[string]any); ok {
		for k, v := range hMap {
			headers[k] = valueToString(v)
		}
	}

	expectedHeaders := map[string]string{}
	if ehMap, ok := raw["expected_headers"].(map[string]any); ok {
		for k, v := range ehMap {
			expectedHeaders[k] = valueToString(v)
		}
	}

	var expectedStatuses []int
	if arr, ok := raw["expected_statuses"].([]any); ok {
		for _, item := range arr {
			if code := intFromAny(item, 0); code > 0 {
				expectedStatuses = append(expectedStatuses, code)
			}
		}
	}
	expectedStatus := 0
	if arr, ok := raw["expected_status"].([]any); ok {
		for _, item := range arr {
			if code := intFromAny(item, 0); code > 0 {
				expectedStatuses = append(expectedStatuses, code)
			}
		}
	} else {
		expectedStatus = intFromAny(raw["expected_status"], 0)
	}

	extractions := parseExtractions(raw["extract"])
	if len(extractions) == 0 {
		extractions = parseExtractions(raw["extractions"])
	}

	return httpStepSpec{
		ID:                 id,
		Method:             method,
		URL:                stringFromAny(raw["url"]),
		Headers:            headers,
		Body:               stringFromAny(raw["body"]),
		CredentialSlot:     firstNonEmptyString(raw["credential_slot"], raw["auth_slot"]),
		TimeoutMS:          timeout,
		InsecureSkipVerify: boolFromAny(raw["insecure_skip_verify"], false),
		FollowRedirects:    boolFromAny(raw["follow_redirects"], true),
		ExpectedStatus:     expectedStatus,
		ExpectedStatuses:   expectedStatuses,
		ExpectedHeaders:    expectedHeaders,
		BodyContains:       stringFromAny(raw["body_contains"]),
		BodyRegex:          stringFromAny(raw["body_regex"]),
		JSONAssertions:     sliceOfMaps(raw["json_assertions"]),
		Extractions:        extractions,
	}
}

func parseExtractions(raw any) []stepExtractionSpec {
	var out []stepExtractionSpec
	switch typed := raw.(type) {
	case []any:
		for _, item := range typed {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			name := firstNonEmptyString(m["name"], m["var"], m["as"])
			if name == "" {
				continue
			}
			out = append(out, stepExtractionSpec{
				Name:    name,
				From:    stringFromAny(m["from"]),
				Path:    firstNonEmptyString(m["path"], m["json_path"]),
				Header:  stringFromAny(m["header"]),
				Pattern: firstNonEmptyString(m["pattern"], m["regex"]),
				Secret:  boolFromAny(m["secret"], false),
			})
		}
	case map[string]any:
		keys := make([]string, 0, len(typed))
		for k := range typed {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			switch v := typed[k].(type) {
			case string:
				out = append(out, stepExtractionSpec{
					Name: k,
					From: "json_path",
					Path: v,
				})
			case map[string]any:
				out = append(out, stepExtractionSpec{
					Name:    k,
					From:    stringFromAny(v["from"]),
					Path:    firstNonEmptyString(v["path"], v["json_path"]),
					Header:  stringFromAny(v["header"]),
					Pattern: firstNonEmptyString(v["pattern"], v["regex"]),
					Secret:  boolFromAny(v["secret"], false),
				})
			}
		}
	}
	return out
}

func buildDNSWireQuery(txID uint16, qname string, qtype uint16) ([]byte, error) {
	trimmed := strings.TrimSuffix(strings.TrimSpace(qname), ".")
	if trimmed == "" {
		return nil, sentinelError("empty domain name")
	}
	labels := strings.Split(trimmed, ".")
	out := make([]byte, 12, 64)
	binary.BigEndian.PutUint16(out[0:2], txID)
	binary.BigEndian.PutUint16(out[2:4], 0x0100) // RD=1
	binary.BigEndian.PutUint16(out[4:6], 1)      // QDCOUNT=1

	for _, label := range labels {
		if len(label) == 0 || len(label) > 63 {
			return nil, sentinelError("invalid dns label length")
		}
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	out = append(out, 0)
	var tail [4]byte
	binary.BigEndian.PutUint16(tail[0:2], qtype)
	binary.BigEndian.PutUint16(tail[2:4], 1) // IN
	out = append(out, tail[:]...)
	return out, nil
}

func parseDNSWireResponse(expectedID uint16, msg []byte, wantQType uint16) (int, []string, error) {
	if len(msg) < 12 {
		return 0, nil, sentinelError("dns packet shorter than header")
	}
	id := binary.BigEndian.Uint16(msg[0:2])
	if id != expectedID {
		return 0, nil, sentinelError("dns transaction id mismatch")
	}
	flags := binary.BigEndian.Uint16(msg[2:4])
	if flags&0x8000 == 0 {
		return 0, nil, sentinelError("dns packet is not a response")
	}
	rcode := int(flags & 0x000F)
	qdCount := int(binary.BigEndian.Uint16(msg[4:6]))
	anCount := int(binary.BigEndian.Uint16(msg[6:8]))

	offset := 12
	for i := 0; i < qdCount; i++ {
		_, nextOff, err := readDNSName(msg, offset)
		if err != nil {
			return rcode, nil, err
		}
		if nextOff+4 > len(msg) {
			return rcode, nil, sentinelError("truncated dns question")
		}
		offset = nextOff + 4
	}

	var answers []string
	for i := 0; i < anCount; i++ {
		_, nextOff, err := readDNSName(msg, offset)
		if err != nil {
			return rcode, nil, err
		}
		if nextOff+10 > len(msg) {
			return rcode, nil, sentinelError("truncated dns resource record")
		}
		rrType := binary.BigEndian.Uint16(msg[nextOff : nextOff+2])
		rdLen := int(binary.BigEndian.Uint16(msg[nextOff+8 : nextOff+10]))
		rdataStart := nextOff + 10
		rdataEnd := rdataStart + rdLen
		if rdataEnd > len(msg) {
			return rcode, nil, sentinelError("truncated dns rdata")
		}
		if rrType == wantQType || (wantQType != 5 && rrType != 5) {
			if decoded, ok := decodeDNSRData(msg, rrType, rdataStart, rdLen); ok && rrType == wantQType {
				answers = append(answers, decoded)
			}
		}
		offset = rdataEnd
	}
	return rcode, answers, nil
}

func decodeDNSRData(msg []byte, rrType uint16, start, rdLen int) (string, bool) {
	rdata := msg[start : start+rdLen]
	switch rrType {
	case 1: // A
		if len(rdata) != 4 {
			return "", false
		}
		return formatIPBytes(rdata), true
	case 28: // AAAA
		if len(rdata) != 16 {
			return "", false
		}
		return formatIPBytes(rdata), true
	case 2, 5, 12: // NS, CNAME, PTR
		name, _, err := readDNSName(msg, start)
		if err != nil {
			return "", false
		}
		return strings.TrimSuffix(name, "."), true
	case 15: // MX
		if len(rdata) < 3 {
			return "", false
		}
		name, _, err := readDNSName(msg, start+2)
		if err != nil {
			return "", false
		}
		return strings.TrimSuffix(name, "."), true
	case 16: // TXT
		var sb strings.Builder
		pos := 0
		for pos < len(rdata) {
			txtLen := int(rdata[pos])
			pos++
			if pos+txtLen > len(rdata) {
				return "", false
			}
			sb.Write(rdata[pos : pos+txtLen])
			pos += txtLen
		}
		return sb.String(), true
	default:
		return "", false
	}
}

func readDNSName(msg []byte, start int) (string, int, error) {
	var (
		labels  []string
		pos     = start
		nextPos = -1
		jumped  = false
	)
	for hops := 0; hops < 64; hops++ {
		if pos >= len(msg) {
			return "", 0, sentinelError("dns name out of bounds")
		}
		length := int(msg[pos])
		if length == 0 {
			if !jumped {
				nextPos = pos + 1
			}
			return strings.Join(labels, "."), nextPos, nil
		}
		if length&0xC0 == 0xC0 {
			if pos+1 >= len(msg) {
				return "", 0, sentinelError("truncated dns pointer")
			}
			if !jumped {
				nextPos = pos + 2
				jumped = true
			}
			pos = ((length & 0x3F) << 8) | int(msg[pos+1])
			continue
		}
		pos++
		if pos+length > len(msg) {
			return "", 0, sentinelError("truncated dns label")
		}
		labels = append(labels, string(msg[pos:pos+length]))
		pos += length
	}
	return "", 0, sentinelError("dns compression pointer loop")
}

func dnsTypeCode(name string) uint16 {
	switch name {
	case "A":
		return 1
	case "NS":
		return 2
	case "CNAME":
		return 5
	case "PTR":
		return 12
	case "MX":
		return 15
	case "TXT":
		return 16
	case "AAAA":
		return 28
	default:
		return 0
	}
}

func containsAllAnswers(actual, expected []string) bool {
	for _, want := range expected {
		found := false
		for _, got := range actual {
			if strings.EqualFold(strings.TrimSuffix(got, "."), strings.TrimSuffix(strings.TrimSpace(want), ".")) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}

func formatTLSVersion(v uint16) string {
	switch v {
	case tlsVersion13:
		return "TLSv1.3"
	case tlsVersion12:
		return "TLSv1.2"
	case tlsVersion11:
		return "TLSv1.1"
	case tlsVersion10:
		return "TLSv1.0"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}

func tlsVersionRank(ver string) int {
	switch strings.ToUpper(strings.TrimSpace(ver)) {
	case "TLSV1.3", "1.3":
		return 4
	case "TLSV1.2", "1.2":
		return 3
	case "TLSV1.1", "1.1":
		return 2
	case "TLSV1.0", "1.0":
		return 1
	default:
		return 0
	}
}

func effectiveURLPort(u *url.URL) int {
	if raw := u.Port(); raw != "" {
		if p, err := strconv.Atoi(raw); err == nil && p > 0 && p <= 65535 {
			return p
		}
	}
	if strings.EqualFold(u.Scheme, "https") {
		return 443
	}
	return 80
}

func isRedirectStatus(code int) bool {
	switch code {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		return true
	default:
		return false
	}
}

func stripSensitiveRedirectHeaders(in map[string]string) map[string]string {
	out := make(map[string]string, len(in))
	for k, v := range in {
		if isSensitiveKey(k) {
			continue
		}
		out[k] = v
	}
	return out
}

func redactHTTPHeaders(in map[string]string, ctx *evalContext) map[string]string {
	if len(in) == 0 {
		return map[string]string{}
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		if isSensitiveKey(k) {
			out[k] = redactedPlaceholder
		} else {
			out[k] = ctx.scrubString(v)
		}
	}
	return out
}

func headerCaseInsensitive(headers map[string]string, name string) string {
	if v, ok := headers[name]; ok {
		return v
	}
	for k, v := range headers {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

func splitHostPortOptional(raw string) (string, int, bool) {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "[") {
		idx := strings.Index(raw, "]:")
		if idx < 0 {
			return "", 0, false
		}
		host := raw[1:idx]
		p, err := strconv.Atoi(raw[idx+2:])
		if err != nil || p < 1 || p > 65535 {
			return "", 0, false
		}
		return host, p, true
	}
	if strings.Count(raw, ":") == 1 {
		idx := strings.IndexByte(raw, ':')
		host := raw[:idx]
		p, err := strconv.Atoi(raw[idx+1:])
		if err != nil || p < 1 || p > 65535 || host == "" {
			return "", 0, false
		}
		return host, p, true
	}
	return "", 0, false
}

func parseLiteralIP(raw string) ([]byte, bool) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if s == "" {
		return nil, false
	}
	if strings.Contains(s, ":") {
		return parseIPv6Literal(s)
	}
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return nil, false
	}
	out := make([]byte, 4)
	for i, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return nil, false
		}
		val, err := strconv.Atoi(part)
		if err != nil || val < 0 || val > 255 {
			return nil, false
		}
		out[i] = byte(val)
	}
	return out, true
}

func parseIPv6Literal(s string) ([]byte, bool) {
	parts := strings.Split(s, "::")
	if len(parts) > 2 {
		return nil, false
	}
	parseGroups := func(seg string) ([]uint16, bool) {
		if seg == "" {
			return nil, true
		}
		items := strings.Split(seg, ":")
		groups := make([]uint16, 0, len(items))
		for _, item := range items {
			if item == "" || len(item) > 4 {
				return nil, false
			}
			v, err := strconv.ParseUint(item, 16, 16)
			if err != nil {
				return nil, false
			}
			groups = append(groups, uint16(v))
		}
		return groups, true
	}
	left, okL := parseGroups(parts[0])
	if !okL {
		return nil, false
	}
	if len(parts) == 1 {
		if len(left) != 8 {
			return nil, false
		}
		out := make([]byte, 16)
		for i, g := range left {
			binary.BigEndian.PutUint16(out[i*2:i*2+2], g)
		}
		return out, true
	}
	right, okR := parseGroups(parts[1])
	if !okR || len(left)+len(right) >= 8 {
		return nil, false
	}
	out := make([]byte, 16)
	for i, g := range left {
		binary.BigEndian.PutUint16(out[i*2:i*2+2], g)
	}
	rightStart := 8 - len(right)
	for i, g := range right {
		idx := rightStart + i
		binary.BigEndian.PutUint16(out[idx*2:idx*2+2], g)
	}
	return out, true
}

func cidrContainsIP(cidr string, ip []byte) bool {
	slash := strings.IndexByte(cidr, '/')
	if slash < 0 {
		netIP, ok := parseLiteralIP(cidr)
		return ok && equalBytes(netIP, ip)
	}
	netIP, ok := parseLiteralIP(cidr[:slash])
	if !ok || len(netIP) != len(ip) {
		return false
	}
	bits, err := strconv.Atoi(cidr[slash+1:])
	maxBits := len(ip) * 8
	if err != nil || bits < 0 || bits > maxBits {
		return false
	}
	fullBytes := bits / 8
	for i := 0; i < fullBytes; i++ {
		if netIP[i] != ip[i] {
			return false
		}
	}
	remBits := bits % 8
	if remBits > 0 {
		mask := byte(0xff << uint(8-remBits))
		if (netIP[fullBytes] & mask) != (ip[fullBytes] & mask) {
			return false
		}
	}
	return true
}

func formatIPBytes(b []byte) string {
	if len(b) == 4 {
		return strconv.Itoa(int(b[0])) + "." + strconv.Itoa(int(b[1])) + "." + strconv.Itoa(int(b[2])) + "." + strconv.Itoa(int(b[3]))
	}
	if len(b) == 16 {
		var parts [8]string
		for i := 0; i < 8; i++ {
			parts[i] = strconv.FormatUint(uint64(binary.BigEndian.Uint16(b[i*2:i*2+2])), 16)
		}
		return strings.Join(parts[:], ":")
	}
	return ""
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
