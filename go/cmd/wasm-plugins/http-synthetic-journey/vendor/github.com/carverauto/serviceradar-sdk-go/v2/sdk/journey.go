package sdk

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// StepStatus describes the execution outcome of a single Journey step.
type StepStatus string

const (
	StepStatusOK       StepStatus = "OK"
	StepStatusWarning  StepStatus = "WARNING"
	StepStatusCritical StepStatus = "CRITICAL"
	StepStatusSkipped  StepStatus = "SKIPPED"
)

type stepAssertionKind uint8

const (
	assertStatus stepAssertionKind = iota + 1
	assertStatusRange
	assertHeaderExact
	assertHeaderContains
	assertBodyContains
	assertJSONField
	assertMaxDuration
	assertMinCertDays
)

type stepAssertion struct {
	kind       stepAssertionKind
	codes      []int
	minCode    int
	maxCode    int
	name       string
	expected   string
	jsonExpect any
	warnFloat  float64
	critFloat  float64
	warnInt    int
	critInt    int
}

type stepExtractorKind uint8

const (
	extractHeader stepExtractorKind = iota + 1
	extractCookie
	extractJSONField
)

type stepExtractor struct {
	kind    stepExtractorKind
	source  string
	varName string
}

// Step configures one HTTP step inside a Journey.
type Step struct {
	journey         *Journey
	name            string
	method          string
	url             string
	headers         map[string]string
	body            []byte
	bodyBase64      bool
	timeoutMS       int
	followRedirects *bool
	insecureTLS     bool
	assertions      []stepAssertion
	extractors      []stepExtractor
}

// Journey orchestrates a multi-step synthetic HTTP workflow with scoped
// RFC 6265 cookie handling, redacted variable extraction, waterfall widgets,
// and canonical synthetic.* metric emission.
type Journey struct {
	name          string
	steps         []*Step
	httpClient    *HTTPClient
	webPropertyID string
	targetCtx     *TargetContext
	deviceID      string
	targetIP      string
	producerID    string
	emitTelemetry bool
	nowFn         func() time.Time
}

// StepOutcome captures sanitized execution telemetry for one step.
type StepOutcome struct {
	Name             string
	Method           string
	URL              string
	Status           StepStatus
	HTTPStatus       int
	DurationMS       float64
	DNSMS            float64
	ConnectMS        float64
	TLSMS            float64
	TTFBMS           float64
	TransferMS       float64
	ConnectionReused bool
	RedirectCount    int
	Protocol         string
	RemoteAddr       string
	TLSCertDays      *int
	Error            string
}

// JourneyReport contains the Result, MetricBatch, TelemetryBatch, and step outcomes
// produced by executing a Journey.
type JourneyReport struct {
	Status         Status
	Steps          []StepOutcome
	StepsCompleted int
	TotalMS        float64
	Result         *Result
	MetricBatch    MetricBatch
	TelemetryBatch TelemetryBatch
}

// NewJourney creates a new synthetic HTTP Journey builder.
func NewJourney(name string) *Journey {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "http-synthetic-journey"
	}
	return &Journey{
		name:          name,
		emitTelemetry: true,
	}
}

// WithHTTPClient overrides the HTTPClient used by the Journey (default sdk.HTTP).
func (j *Journey) WithHTTPClient(client *HTTPClient) *Journey {
	j.httpClient = client
	return j
}

// WithWebPropertyID attaches an optional web_property_id attribute to emitted
// synthetic metrics and result labels for WebProperty attribution.
func (j *Journey) WithWebPropertyID(id string) *Journey {
	j.webPropertyID = strings.TrimSpace(id)
	return j
}

// WithTargetContext attaches descriptor-aware target metadata to the Result
// and MetricResource.
func (j *Journey) WithTargetContext(ctx TargetContext) *Journey {
	copyCtx := ctx
	j.targetCtx = &copyCtx
	return j
}

// WithDeviceID sets MetricResource.DeviceID.
func (j *Journey) WithDeviceID(id string) *Journey {
	j.deviceID = strings.TrimSpace(id)
	return j
}

// WithTargetDeviceIP sets MetricResource.TargetDeviceIP.
func (j *Journey) WithTargetDeviceIP(ip string) *Journey {
	j.targetIP = strings.TrimSpace(ip)
	return j
}

// WithProducerID sets MetricIngestIdentity.ProducerID.
func (j *Journey) WithProducerID(id string) *Journey {
	j.producerID = strings.TrimSpace(id)
	return j
}

// WithTelemetry controls whether Run/RunContext emits MetricBatch telemetry.
func (j *Journey) WithTelemetry(enabled bool) *Journey {
	j.emitTelemetry = enabled
	return j
}

// Step appends a new step to the Journey and returns it for configuration.
func (j *Journey) Step(name, method, rawURL string) *Step {
	method = strings.ToUpper(strings.TrimSpace(method))
	if method == "" {
		method = http.MethodGet
	}
	s := &Step{
		journey: j,
		name:    strings.TrimSpace(name),
		method:  method,
		url:     strings.TrimSpace(rawURL),
	}
	if s.name == "" {
		s.name = fmt.Sprintf("step-%d", len(j.steps)+1)
	}
	j.steps = append(j.steps, s)
	return s
}

// AddStep appends an existing Step to the Journey.
func (j *Journey) AddStep(step *Step) *Journey {
	if step != nil {
		step.journey = j
		j.steps = append(j.steps, step)
	}
	return j
}

// Journey returns the parent Journey builder for chaining.
func (s *Step) Journey() *Journey {
	return s.journey
}

// Step appends another step onto the parent Journey and returns the new Step.
func (s *Step) Step(name, method, rawURL string) *Step {
	return s.journey.Step(name, method, rawURL)
}

func (s *Step) WithHeader(key, value string) *Step {
	if strings.TrimSpace(key) == "" {
		return s
	}
	if s.headers == nil {
		s.headers = make(map[string]string)
	}
	s.headers[key] = value
	return s
}

func (s *Step) WithHeaders(headers map[string]string) *Step {
	for k, v := range headers {
		s.WithHeader(k, v)
	}
	return s
}

func (s *Step) WithBody(body []byte) *Step {
	s.body = append([]byte(nil), body...)
	s.bodyBase64 = false
	return s
}

func (s *Step) WithTextBody(body string) *Step {
	s.body = []byte(body)
	s.bodyBase64 = false
	return s
}

func (s *Step) WithJSONBody(body string) *Step {
	s.body = []byte(body)
	s.bodyBase64 = false
	return s.WithHeader("Content-Type", "application/json")
}

func (s *Step) WithBinaryBody(body []byte) *Step {
	s.body = append([]byte(nil), body...)
	s.bodyBase64 = true
	return s
}

func (s *Step) WithTimeout(d time.Duration) *Step {
	if d > 0 {
		s.timeoutMS = int(d / time.Millisecond)
		if s.timeoutMS == 0 {
			s.timeoutMS = 1
		}
	}
	return s
}

func (s *Step) WithTimeoutMS(ms int) *Step {
	if ms > 0 {
		s.timeoutMS = ms
	}
	return s
}

func (s *Step) WithFollowRedirects(follow bool) *Step {
	s.followRedirects = Bool(follow)
	return s
}

func (s *Step) WithInsecureTLS(skip bool) *Step {
	s.insecureTLS = skip
	return s
}

func (s *Step) ExpectStatus(codes ...int) *Step {
	copied := append([]int(nil), codes...)
	s.assertions = append(s.assertions, stepAssertion{kind: assertStatus, codes: copied})
	return s
}

func (s *Step) ExpectStatusRange(minCode, maxCode int) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:    assertStatusRange,
		minCode: minCode,
		maxCode: maxCode,
	})
	return s
}

func (s *Step) ExpectHeader(name, expected string) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:     assertHeaderExact,
		name:     name,
		expected: expected,
	})
	return s
}

func (s *Step) ExpectHeaderContains(name, substr string) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:     assertHeaderContains,
		name:     name,
		expected: substr,
	})
	return s
}

func (s *Step) ExpectBodyContains(substr string) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:     assertBodyContains,
		expected: substr,
	})
	return s
}

func (s *Step) ExpectJSONField(pointer string, expected any) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:       assertJSONField,
		name:       pointer,
		jsonExpect: expected,
	})
	return s
}

func (s *Step) ExpectMaxDuration(warnMS, critMS float64) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:      assertMaxDuration,
		warnFloat: warnMS,
		critFloat: critMS,
	})
	return s
}

// ExpectMinCertDays asserts minimum remaining TLS leaf certificate days.
// Passing a negative threshold disables that severity level.
func (s *Step) ExpectMinCertDays(warnDays, critDays int) *Step {
	s.assertions = append(s.assertions, stepAssertion{
		kind:    assertMinCertDays,
		warnInt: warnDays,
		critInt: critDays,
	})
	return s
}

func (s *Step) ExtractHeader(headerName, varName string) *Step {
	s.extractors = append(s.extractors, stepExtractor{
		kind:    extractHeader,
		source:  headerName,
		varName: varName,
	})
	return s
}

func (s *Step) ExtractCookie(cookieName, varName string) *Step {
	s.extractors = append(s.extractors, stepExtractor{
		kind:    extractCookie,
		source:  cookieName,
		varName: varName,
	})
	return s
}

func (s *Step) ExtractJSONField(pointer, varName string) *Step {
	s.extractors = append(s.extractors, stepExtractor{
		kind:    extractJSONField,
		source:  pointer,
		varName: varName,
	})
	return s
}

// Run executes the Journey, emits synthetic.* telemetry when enabled, and
// returns the resulting PluginResult.
func (j *Journey) Run() (*Result, error) {
	return j.RunContext(context.Background())
}

// RunContext executes the Journey with ctx, emits synthetic.* telemetry when
// enabled, and returns the resulting PluginResult.
func (j *Journey) RunContext(ctx context.Context) (*Result, error) {
	report, err := j.Execute(ctx)
	if err != nil {
		return nil, err
	}
	if j.emitTelemetry && len(report.TelemetryBatch.Records) > 0 {
		if emitErr := EmitTelemetry(report.TelemetryBatch); emitErr != nil {
			return nil, emitErr
		}
	}
	return report.Result, nil
}

// Execute runs all Journey steps and builds the Result and MetricBatch without
// submitting them to the host.
func (j *Journey) Execute(ctx context.Context) (*JourneyReport, error) {
	if j == nil {
		return nil, fmt.Errorf("journey is nil")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	client := j.httpClient
	if client == nil {
		client = HTTP
	}
	nowFn := j.nowFn
	if nowFn == nil {
		nowFn = func() time.Time { return time.Now().UTC() }
	}

	jar := NewCookieJar()
	jar.nowFn = nowFn
	vars := make(map[string]string)

	outcomes := make([]StepOutcome, 0, len(j.steps))
	overallStatus := StatusOK
	var firstCriticalReason string
	var firstCriticalStep string
	var firstWarningReason string
	stepsCompleted := 0
	var totalDurationMS float64
	shortCircuit := false

	stepMetrics := make([]Metric, 0, len(j.steps)*7)
	pointTimeNano := uint64(nowFn().UTC().UnixNano())

	for idx, step := range j.steps {
		sanitizedBaseURL := sanitizeURLForTelemetry(step.url)
		if shortCircuit {
			outcomes = append(outcomes, StepOutcome{
				Name:   step.name,
				Method: step.method,
				URL:    sanitizedBaseURL,
				Status: StepStatusSkipped,
			})
			continue
		}

		outcome, resp, errReason, warnReason := j.runStep(ctx, client, jar, vars, step, nowFn())
		outcomes = append(outcomes, outcome)

		if outcome.Status == StepStatusCritical {
			overallStatus = StatusCritical
			shortCircuit = true
			if firstCriticalReason == "" {
				firstCriticalStep = step.name
				firstCriticalReason = errReason
			}
		} else {
			stepsCompleted++
			if outcome.Status == StepStatusWarning && overallStatus != StatusCritical {
				overallStatus = StatusWarning
				if firstWarningReason == "" {
					firstWarningReason = warnReason
				}
			}
		}
		totalDurationMS += outcome.DurationMS

		stepMetrics = append(stepMetrics, j.buildStepMetrics(idx, outcome, resp, pointTimeNano)...)
	}

	if totalDurationMS == 0 && len(outcomes) > 0 {
		// Ensure non-zero positive clock fallback only if needed; keep real measured duration.
		totalDurationMS = 0
	}

	res := j.buildResult(overallStatus, outcomes, stepsCompleted, totalDurationMS, firstCriticalStep, firstCriticalReason, firstWarningReason)
	batch := j.buildMetricBatch(overallStatus, stepsCompleted, totalDurationMS, stepMetrics, pointTimeNano)
	eventID := fmt.Sprintf("journey-%s-%d", j.name, pointTimeNano)
	telemetryBatch := TelemetryBatch{
		Source: TelemetrySource{
			SourceType:     "plugin",
			SourceInstance: j.name,
		},
		Records: []TelemetryRecord{
			NewServiceRadarMetricTelemetryRecordFromBatch(eventID, batch),
		},
	}

	return &JourneyReport{
		Status:         overallStatus,
		Steps:          outcomes,
		StepsCompleted: stepsCompleted,
		TotalMS:        totalDurationMS,
		Result:         res,
		MetricBatch:    batch,
		TelemetryBatch: telemetryBatch,
	}, nil
}

func (j *Journey) runStep(
	ctx context.Context,
	client *HTTPClient,
	jar *CookieJar,
	vars map[string]string,
	step *Step,
	now time.Time,
) (StepOutcome, *HTTPResponse, string, string) {
	outcome := StepOutcome{
		Name:   step.name,
		Method: step.method,
		URL:    sanitizeURLForTelemetry(step.url),
		Status: StepStatusOK,
	}

	resolvedURL, err := replaceTemplateVars(step.url, vars)
	if err != nil {
		outcome.Status = StepStatusCritical
		outcome.Error = err.Error()
		return outcome, nil, err.Error(), ""
	}
	outcome.URL = sanitizeURLForTelemetry(resolvedURL)

	resolvedHeaders := make(map[string]string, len(step.headers)+1)
	var explicitCookieHeader string
	for k, v := range step.headers {
		resolvedVal, tplErr := replaceTemplateVars(v, vars)
		if tplErr != nil {
			outcome.Status = StepStatusCritical
			outcome.Error = tplErr.Error()
			return outcome, nil, tplErr.Error(), ""
		}
		if strings.EqualFold(k, "Cookie") {
			if explicitCookieHeader == "" {
				explicitCookieHeader = resolvedVal
			} else if resolvedVal != "" {
				explicitCookieHeader += "; " + resolvedVal
			}
			continue
		}
		resolvedHeaders[k] = resolvedVal
	}

	jarCookieHeader := jar.headerValueAt(resolvedURL, now)
	if mergedCookies := mergeCookieHeaders(jarCookieHeader, explicitCookieHeader); mergedCookies != "" {
		resolvedHeaders["Cookie"] = mergedCookies
	}

	resolvedBody := step.body
	if !step.bodyBase64 && len(step.body) > 0 {
		expandedBody, tplErr := replaceTemplateVars(string(step.body), vars)
		if tplErr != nil {
			outcome.Status = StepStatusCritical
			outcome.Error = tplErr.Error()
			return outcome, nil, tplErr.Error(), ""
		}
		resolvedBody = []byte(expandedBody)
	}

	req := HTTPRequest{
		Method:             step.method,
		URL:                resolvedURL,
		Headers:            resolvedHeaders,
		Body:               resolvedBody,
		BodyBase64:         step.bodyBase64,
		ResponseMode:       ResponseModeEnvelope,
		TimeoutMS:          step.timeoutMS,
		InsecureSkipVerify: step.insecureTLS,
		FollowRedirects:    step.followRedirects,
	}

	resp, reqErr := client.DoContext(ctx, req)
	if reqErr != nil {
		msg := sanitizeErrorMessage(reqErr, vars)
		outcome.Status = StepStatusCritical
		outcome.Error = msg
		return outcome, nil, msg, ""
	}

	outcome.HTTPStatus = resp.Status
	if resp.Trace != nil {
		if resp.Trace.FinalURL != "" {
			outcome.URL = sanitizeURLForTelemetry(resp.Trace.FinalURL)
		}
		outcome.DNSMS = nsToMS(resp.Trace.DNSDurationNS)
		outcome.ConnectMS = nsToMS(resp.Trace.ConnectDurationNS)
		outcome.TLSMS = nsToMS(resp.Trace.TLSHandshakeDurationNS)
		outcome.TTFBMS = nsToMS(resp.Trace.TTFBDurationNS)
		outcome.TransferMS = nsToMS(resp.Trace.TransferDurationNS)
		if resp.Trace.TotalDurationNS > 0 {
			outcome.DurationMS = nsToMS(resp.Trace.TotalDurationNS)
		} else {
			outcome.DurationMS = float64(resp.Duration.Nanoseconds()) / 1e6
		}
		outcome.ConnectionReused = resp.Trace.ConnectionReused
		outcome.RedirectCount = resp.Trace.RedirectCount
		outcome.Protocol = resp.Trace.Protocol
		outcome.RemoteAddr = resp.Trace.RemoteAddr
	} else {
		outcome.DurationMS = float64(resp.Duration.Nanoseconds()) / 1e6
	}
	if resp.TLS != nil && resp.TLS.LeafDaysRemaining != nil {
		days := *resp.TLS.LeafDaysRemaining
		outcome.TLSCertDays = &days
	}

	effectiveURL := resolvedURL
	if resp.Trace != nil && resp.Trace.FinalURL != "" {
		effectiveURL = resp.Trace.FinalURL
	}
	setCookies := resp.HeaderValues("Set-Cookie")
	jar.storeResponseCookiesAt(effectiveURL, setCookies, now)
	var stepJar *CookieJar

	// Decode JSON once lazily if assertions or extractors need it.
	var jsonParsed bool
	var jsonRoot any
	var jsonErr error
	ensureJSON := func() (any, error) {
		if !jsonParsed {
			jsonParsed = true
			dec := json.NewDecoder(bytes.NewReader(resp.Body))
			dec.UseNumber()
			if err := dec.Decode(&jsonRoot); err != nil {
				jsonErr = err
			}
		}
		return jsonRoot, jsonErr
	}

	var warnReasons []string
	for _, a := range step.assertions {
		switch a.kind {
		case assertStatus:
			matched := false
			for _, code := range a.codes {
				if resp.Status == code {
					matched = true
					break
				}
			}
			if !matched {
				msg := fmt.Sprintf("status %d did not match expected %v", resp.Status, a.codes)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertStatusRange:
			if resp.Status < a.minCode || resp.Status > a.maxCode {
				msg := fmt.Sprintf("status %d outside expected range [%d, %d]", resp.Status, a.minCode, a.maxCode)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertHeaderExact:
			got := resp.Header(a.name)
			if a.expected == "" {
				if got == "" {
					msg := fmt.Sprintf("missing header %q", a.name)
					outcome.Status = StepStatusCritical
					outcome.Error = msg
					return outcome, resp, msg, ""
				}
			} else if got != a.expected {
				msg := fmt.Sprintf("header %q mismatch", a.name)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertHeaderContains:
			got := resp.Header(a.name)
			if !strings.Contains(got, a.expected) {
				msg := fmt.Sprintf("header %q missing expected substring", a.name)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertBodyContains:
			if !bytes.Contains(resp.Body, []byte(a.expected)) {
				msg := fmt.Sprintf("response body missing expected substring %q", a.expected)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertJSONField:
			root, err := ensureJSON()
			if err != nil {
				msg := fmt.Sprintf("invalid JSON body checking %q", a.name)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			actual, ok := resolveJSONPath(root, a.name)
			if !ok || !jsonValuesEqual(actual, a.jsonExpect) {
				msg := fmt.Sprintf("JSON field %q did not match expected value", a.name)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
		case assertMaxDuration:
			if a.critFloat > 0 && outcome.DurationMS >= a.critFloat {
				msg := fmt.Sprintf("duration %.1fms >= critical %.1fms", outcome.DurationMS, a.critFloat)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			if a.warnFloat > 0 && outcome.DurationMS >= a.warnFloat {
				warnReasons = append(warnReasons, fmt.Sprintf("duration %.1fms >= warning %.1fms", outcome.DurationMS, a.warnFloat))
			}
		case assertMinCertDays:
			if outcome.TLSCertDays == nil {
				msg := "TLS certificate expiry unavailable for minimum certificate days check"
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			days := *outcome.TLSCertDays
			if a.critInt >= 0 && days <= a.critInt {
				msg := fmt.Sprintf("TLS certificate expires in %d days (<= critical %d)", days, a.critInt)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			if a.warnInt >= 0 && days <= a.warnInt {
				warnReasons = append(warnReasons, fmt.Sprintf("TLS certificate expires in %d days (<= warning %d)", days, a.warnInt))
			}
		}
	}

	for _, ex := range step.extractors {
		switch ex.kind {
		case extractHeader:
			val := resp.Header(ex.source)
			if val == "" {
				msg := fmt.Sprintf("extractor %q: missing header %q", ex.varName, ex.source)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			vars[ex.varName] = val
		case extractCookie:
			val, ok := jar.getAt(effectiveURL, ex.source, now)
			if !ok && effectiveURL != resolvedURL {
				val, ok = jar.getAt(resolvedURL, ex.source, now)
			}
			if !ok && len(setCookies) > 0 {
				// Also check cookies parsed directly from this step's Set-Cookie
				// headers in case Path scopes the cookie to a subsequent URL.
				if stepJar == nil {
					stepJar = NewCookieJar()
					stepJar.nowFn = jar.nowFn
					stepJar.storeResponseCookiesAt(effectiveURL, setCookies, now)
				}
				val, ok = findAcceptedCookieInJar(stepJar, ex.source, isHTTPSURL(effectiveURL))
			}
			if !ok {
				msg := fmt.Sprintf("extractor %q: missing cookie %q", ex.varName, ex.source)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			vars[ex.varName] = val
		case extractJSONField:
			root, err := ensureJSON()
			if err != nil {
				msg := fmt.Sprintf("extractor %q: invalid JSON body for %q", ex.varName, ex.source)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			val, ok := resolveJSONPath(root, ex.source)
			if !ok {
				msg := fmt.Sprintf("extractor %q: missing JSON field %q", ex.varName, ex.source)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			strVal, ok := jsonScalarToString(val)
			if !ok {
				msg := fmt.Sprintf("extractor %q: JSON field %q is not scalar", ex.varName, ex.source)
				outcome.Status = StepStatusCritical
				outcome.Error = msg
				return outcome, resp, msg, ""
			}
			vars[ex.varName] = strVal
		}
	}

	if len(warnReasons) > 0 {
		outcome.Status = StepStatusWarning
		outcome.Error = strings.Join(warnReasons, "; ")
		return outcome, resp, "", outcome.Error
	}

	return outcome, resp, "", ""
}

func isHTTPSURL(rawURL string) bool {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(parsed.Scheme), "https")
}

func findAcceptedCookieInJar(jar *CookieJar, name string, isHTTPS bool) (string, bool) {
	if jar == nil {
		return "", false
	}
	for i := len(jar.cookies) - 1; i >= 0; i-- {
		c := jar.cookies[i]
		if c.Name == name && (!c.Secure || isHTTPS) {
			return c.Value, true
		}
	}
	return "", false
}

func (j *Journey) buildResult(
	overallStatus Status,
	outcomes []StepOutcome,
	stepsCompleted int,
	totalDurationMS float64,
	criticalStep string,
	criticalReason string,
	warningReason string,
) *Result {
	res := NewResult()
	if j.targetCtx != nil {
		res.ForTarget(*j.targetCtx)
	}
	res.SetStatus(overallStatus)
	res.AddLabel("journey", j.name)
	if j.webPropertyID != "" {
		res.AddLabel("web_property_id", j.webPropertyID)
	}

	switch overallStatus {
	case StatusCritical:
		res.SetSummary(fmt.Sprintf("journey %s CRITICAL at step %q: %s", j.name, criticalStep, criticalReason))
		res.EmitEvent(SeverityCritical, res.Summary, "synthetic_journey_failed")
		res.RequestImmediateAlert("synthetic_journey_failed")
	case StatusWarning:
		res.SetSummary(fmt.Sprintf("journey %s WARNING (%d/%d steps in %.1fms): %s", j.name, stepsCompleted, len(outcomes), totalDurationMS, warningReason))
		res.EmitEvent(SeverityWarning, res.Summary, "synthetic_journey_degraded")
	default:
		res.SetSummary(fmt.Sprintf("journey %s OK (%d/%d steps in %.1fms)", j.name, stepsCompleted, len(outcomes), totalDurationMS))
	}

	tone := toneForJourneyStatus(overallStatus)
	res.AddStatCard("Journey Status", string(overallStatus), tone)
	res.AddStatCard("Total Duration", fmt.Sprintf("%.1fms", totalDurationMS), tone)
	res.AddStatCard("Steps Completed", fmt.Sprintf("%d/%d", stepsCompleted, len(outcomes)), tone)

	if len(outcomes) > 0 {
		table := make(map[string]string, len(outcomes))
		for idx, step := range outcomes {
			key := fmt.Sprintf("%02d. %s", idx+1, step.Name)
			if step.Status == StepStatusSkipped {
				table[key] = "SKIPPED"
				continue
			}
			val := fmt.Sprintf(
				"%s | %d | %.1fms (dns=%.1f connect=%.1f tls=%.1f ttfb=%.1f xfer=%.1f)",
				step.Status,
				step.HTTPStatus,
				step.DurationMS,
				step.DNSMS,
				step.ConnectMS,
				step.TLSMS,
				step.TTFBMS,
				step.TransferMS,
			)
			if step.RemoteAddr != "" {
				val += " | " + step.RemoteAddr
			}
			if step.TLSCertDays != nil {
				val += fmt.Sprintf(" | tls_days=%d", *step.TLSCertDays)
			}
			if step.Error != "" {
				val += " | " + step.Error
			}
			table[key] = val
		}
		res.AddTable(table, "full")
	}

	return res
}

func (j *Journey) buildStepMetrics(
	idx int,
	outcome StepOutcome,
	resp *HTTPResponse,
	observedAtNano uint64,
) []Metric {
	if outcome.Status == StepStatusSkipped {
		return nil
	}

	host := ""
	if parsed, err := url.Parse(outcome.URL); err == nil {
		host = parsed.Hostname()
	}

	attrs := []MetricStringMapEntry{
		{Key: "journey", Value: j.name},
		{Key: "step", Value: outcome.Name},
		{Key: "step_index", Value: strconv.Itoa(idx)},
		{Key: "method", Value: outcome.Method},
		{Key: "host", Value: host},
		{Key: "status_code", Value: strconv.Itoa(outcome.HTTPStatus)},
	}
	if resp != nil && resp.Trace != nil {
		attrs = append(attrs, MetricStringMapEntry{
			Key:   "connection_reused",
			Value: strconv.FormatBool(resp.Trace.ConnectionReused),
		})
		if resp.Trace.Protocol != "" {
			attrs = append(attrs, MetricStringMapEntry{Key: "protocol", Value: resp.Trace.Protocol})
		}
	}
	if j.webPropertyID != "" {
		attrs = append(attrs, MetricStringMapEntry{Key: "web_property_id", Value: j.webPropertyID})
	}

	makeStepMetric := func(name, unit string, value float64) Metric {
		return Metric{
			Name:       name,
			MetricType: "synthetic",
			Kind:       MetricKindGauge,
			Unit:       unit,
			Points: []MetricPoint{
				{
					Value:              value,
					ObservedAtUnixNano: observedAtNano,
					Attributes:         append([]MetricStringMapEntry(nil), attrs...),
				},
			},
		}
	}

	out := []Metric{
		makeStepMetric("synthetic.step.duration_ms", "ms", outcome.DurationMS),
		makeStepMetric("synthetic.step.dns_ms", "ms", outcome.DNSMS),
		makeStepMetric("synthetic.step.connect_ms", "ms", outcome.ConnectMS),
		makeStepMetric("synthetic.step.tls_ms", "ms", outcome.TLSMS),
		makeStepMetric("synthetic.step.ttfb_ms", "ms", outcome.TTFBMS),
		makeStepMetric("synthetic.step.transfer_ms", "ms", outcome.TransferMS),
	}
	if outcome.TLSCertDays != nil {
		out = append(out, makeStepMetric("synthetic.step.tls_cert_days_remaining", "d", float64(*outcome.TLSCertDays)))
	}
	return out
}

func (j *Journey) buildMetricBatch(
	overallStatus Status,
	stepsCompleted int,
	totalDurationMS float64,
	stepMetrics []Metric,
	observedAtNano uint64,
) MetricBatch {
	deviceID := j.deviceID
	if deviceID == "" && j.targetCtx != nil {
		deviceID = j.targetCtx.DeviceUID()
	}
	producerID := j.producerID
	if producerID == "" {
		producerID = j.name
	}

	resourceAttrs := []MetricStringMapEntry{
		{Key: "journey", Value: j.name},
	}
	journeyPointAttrs := []MetricStringMapEntry{
		{Key: "journey", Value: j.name},
	}
	if j.webPropertyID != "" {
		resourceAttrs = append(resourceAttrs, MetricStringMapEntry{Key: "web_property_id", Value: j.webPropertyID})
		journeyPointAttrs = append(journeyPointAttrs, MetricStringMapEntry{Key: "web_property_id", Value: j.webPropertyID})
	}

	available := 1.0
	if overallStatus == StatusCritical {
		available = 0.0
	}

	makeJourneyMetric := func(name, unit string, value float64) Metric {
		return Metric{
			Name:       name,
			MetricType: "synthetic",
			Kind:       MetricKindGauge,
			Unit:       unit,
			Points: []MetricPoint{
				{
					Value:              value,
					ObservedAtUnixNano: observedAtNano,
					Attributes:         append([]MetricStringMapEntry(nil), journeyPointAttrs...),
				},
			},
		}
	}

	metrics := make([]Metric, 0, 3+len(stepMetrics))
	metrics = append(metrics,
		makeJourneyMetric("synthetic.journey.available", "1", available),
		makeJourneyMetric("synthetic.journey.duration_ms", "ms", totalDurationMS),
		makeJourneyMetric("synthetic.journey.steps_completed", "{step}", float64(stepsCompleted)),
	)
	metrics = append(metrics, stepMetrics...)

	return MetricBatch{
		SchemaVersion: MetricEnvelopeSchemaVersion,
		Resource: MetricResource{
			ServiceName:    j.name,
			ServiceType:    "wasm-plugin",
			DeviceID:       deviceID,
			TargetDeviceIP: j.targetIP,
			Attributes:     resourceAttrs,
		},
		IngestIdentity: MetricIngestIdentity{
			Source:       "plugin-metrics",
			PayloadKind:  MetricEnvelopeSchemaVersion,
			ProducerID:   producerID,
			ProducerKind: "wasm-plugin",
		},
		EmittedAtUnixNano: observedAtNano,
		Metrics:           metrics,
	}
}

func toneForJourneyStatus(status Status) string {
	switch status {
	case StatusOK:
		return "success"
	case StatusWarning:
		return "warning"
	default:
		return "error"
	}
}

func nsToMS(ns int64) float64 {
	if ns <= 0 {
		return 0
	}
	return float64(ns) / 1e6
}

func sanitizeURLForTelemetry(rawURL string) string {
	trimmed := strings.TrimSpace(rawURL)
	if trimmed == "" {
		return ""
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		if idx := strings.IndexAny(trimmed, "?#"); idx >= 0 {
			return trimmed[:idx]
		}
		return trimmed
	}
	parsed.User = nil
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = ""
	parsed.RawFragment = ""
	return parsed.String()
}

func sanitizeErrorMessage(err error, vars map[string]string) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	for _, secret := range vars {
		if secret != "" && strings.Contains(msg, secret) {
			msg = strings.ReplaceAll(msg, secret, "[REDACTED]")
		}
	}
	return msg
}

func replaceTemplateVars(input string, vars map[string]string) (string, error) {
	if !strings.Contains(input, "{{") {
		return input, nil
	}
	var b strings.Builder
	rest := input
	for {
		start := strings.Index(rest, "{{")
		if start < 0 {
			b.WriteString(rest)
			break
		}
		b.WriteString(rest[:start])
		afterStart := rest[start+2:]
		end := strings.Index(afterStart, "}}")
		if end < 0 {
			b.WriteString(rest[start:])
			break
		}
		varName := strings.TrimSpace(afterStart[:end])
		val, ok := vars[varName]
		if !ok {
			return "", fmt.Errorf("missing template variable %q", varName)
		}
		b.WriteString(val)
		rest = afterStart[end+2:]
	}
	return b.String(), nil
}

func mergeCookieHeaders(jarHeader, explicitHeader string) string {
	if explicitHeader == "" {
		return jarHeader
	}
	if jarHeader == "" {
		return explicitHeader
	}

	type cookiePair struct {
		name  string
		value string
	}
	var pairs []cookiePair
	addPairs := func(raw string, override bool) {
		for _, segment := range strings.Split(raw, ";") {
			part := strings.TrimSpace(segment)
			if part == "" {
				continue
			}
			eq := strings.IndexByte(part, '=')
			if eq <= 0 {
				continue
			}
			name := strings.TrimSpace(part[:eq])
			val := strings.TrimSpace(part[eq+1:])
			replaced := false
			if override {
				for i := range pairs {
					if pairs[i].name == name {
						pairs[i].value = val
						replaced = true
						break
					}
				}
			}
			if !replaced {
				pairs = append(pairs, cookiePair{name: name, value: val})
			}
		}
	}

	addPairs(jarHeader, false)
	addPairs(explicitHeader, true)

	var b strings.Builder
	for i, p := range pairs {
		if i > 0 {
			b.WriteString("; ")
		}
		b.WriteString(p.name)
		b.WriteByte('=')
		b.WriteString(p.value)
	}
	return b.String()
}

func resolveJSONPath(root any, path string) (any, bool) {
	if path == "" {
		return root, true
	}

	var tokens []string
	if strings.HasPrefix(path, "/") {
		rawTokens := strings.Split(path[1:], "/")
		tokens = make([]string, len(rawTokens))
		for i, tok := range rawTokens {
			tok = strings.ReplaceAll(tok, "~1", "/")
			tok = strings.ReplaceAll(tok, "~0", "~")
			tokens[i] = tok
		}
	} else {
		for _, part := range strings.Split(path, ".") {
			if part == "" {
				continue
			}
			for {
				open := strings.IndexByte(part, '[')
				if open < 0 {
					if part != "" {
						tokens = append(tokens, part)
					}
					break
				}
				if open > 0 {
					tokens = append(tokens, part[:open])
				}
				closeIdx := strings.IndexByte(part[open+1:], ']')
				if closeIdx < 0 {
					tokens = append(tokens, part[open:])
					break
				}
				idxTok := part[open+1 : open+1+closeIdx]
				tokens = append(tokens, idxTok)
				part = part[open+1+closeIdx+1:]
			}
		}
	}

	curr := root
	for _, tok := range tokens {
		switch node := curr.(type) {
		case map[string]any:
			val, ok := node[tok]
			if !ok {
				return nil, false
			}
			curr = val
		case []any:
			idx, err := strconv.Atoi(tok)
			if err != nil || idx < 0 || idx >= len(node) {
				return nil, false
			}
			curr = node[idx]
		default:
			return nil, false
		}
	}
	return curr, true
}

func jsonValuesEqual(actual, expected any) bool {
	if expected == nil {
		return actual == nil
	}
	switch exp := expected.(type) {
	case map[string]any:
		act, ok := actual.(map[string]any)
		if !ok || len(act) != len(exp) {
			return false
		}
		for k, expVal := range exp {
			actVal, exists := act[k]
			if !exists || !jsonValuesEqual(actVal, expVal) {
				return false
			}
		}
		return true
	case []any:
		act, ok := actual.([]any)
		if !ok || len(act) != len(exp) {
			return false
		}
		for i, expVal := range exp {
			if !jsonValuesEqual(act[i], expVal) {
				return false
			}
		}
		return true
	case string:
		act, ok := actual.(string)
		return ok && act == exp
	case bool:
		act, ok := actual.(bool)
		return ok && act == exp
	case json.Number:
		return jsonNumbersEqual(actual, exp)
	case int:
		return jsonIntEqual(actual, int64(exp))
	case int64:
		return jsonIntEqual(actual, exp)
	case int32:
		return jsonIntEqual(actual, int64(exp))
	case uint:
		return jsonFloatEqual(actual, float64(exp))
	case uint64:
		return jsonFloatEqual(actual, float64(exp))
	case float64:
		return jsonFloatEqual(actual, exp)
	case float32:
		return jsonFloatEqual(actual, float64(exp))
	default:
		return false
	}
}

func jsonNumbersEqual(actual any, expected json.Number) bool {
	if expInt, err := expected.Int64(); err == nil {
		return jsonIntEqual(actual, expInt)
	}
	expFloat, err := expected.Float64()
	if err != nil {
		return false
	}
	return jsonFloatEqual(actual, expFloat)
}

func jsonIntEqual(actual any, expected int64) bool {
	switch act := actual.(type) {
	case json.Number:
		if v, err := act.Int64(); err == nil {
			return v == expected
		}
		if f, err := act.Float64(); err == nil {
			return f == float64(expected)
		}
		return false
	case float64:
		return act == float64(expected)
	case int64:
		return act == expected
	case int:
		return int64(act) == expected
	default:
		return false
	}
}

func jsonFloatEqual(actual any, expected float64) bool {
	switch act := actual.(type) {
	case json.Number:
		f, err := act.Float64()
		return err == nil && f == expected
	case float64:
		return act == expected
	case int64:
		return float64(act) == expected
	case int:
		return float64(act) == expected
	default:
		return false
	}
}

func jsonScalarToString(value any) (string, bool) {
	switch v := value.(type) {
	case string:
		return v, true
	case json.Number:
		return v.String(), true
	case bool:
		return strconv.FormatBool(v), true
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64), true
	case int64:
		return strconv.FormatInt(v, 10), true
	case int:
		return strconv.Itoa(v), true
	default:
		return "", false
	}
}
