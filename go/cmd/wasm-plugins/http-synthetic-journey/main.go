package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	defaultJourneyName = "http-synthetic-journey"
	defaultTimeoutMS   = 10000
	maxJourneySteps    = 64
	redactedSecret     = "[REDACTED]"
)

// Config declares the declarative configuration for the http-synthetic-journey plugin.
type Config struct {
	JourneyName        string       `json:"journey_name"`
	WebPropertyID      string       `json:"web_property_id,omitempty"`
	DeviceID           string       `json:"device_id,omitempty"`
	TargetIP           string       `json:"target_ip,omitempty"`
	EmitTelemetry      *bool        `json:"emit_telemetry,omitempty"`
	TimeoutMS          int          `json:"timeout_ms,omitempty"`
	FollowRedirects    *bool        `json:"follow_redirects,omitempty"`
	InsecureSkipVerify bool         `json:"insecure_skip_verify,omitempty"`
	WarnMS             *float64     `json:"warn_ms,omitempty"`
	CritMS             *float64     `json:"crit_ms,omitempty"`
	MinCertDaysWarn    *int         `json:"min_cert_days_warn,omitempty"`
	MinCertDaysCrit    *int         `json:"min_cert_days_crit,omitempty"`
	APITokenSecretRef  string       `json:"api_token_secret_ref,omitempty"`
	APIToken           string       `json:"api_token,omitempty"`
	Username           string       `json:"username,omitempty"`
	PasswordSecretRef  string       `json:"password_secret_ref,omitempty"`
	Password           string       `json:"password,omitempty"`
	Steps              []StepConfig `json:"steps,omitempty"`
}

// StepConfig describes one ordered HTTP step in a synthetic journey.
type StepConfig struct {
	Name                 string               `json:"name"`
	Method               string               `json:"method,omitempty"`
	URL                  string               `json:"url"`
	Headers              map[string]string    `json:"headers,omitempty"`
	Body                 string               `json:"body,omitempty"`
	ContentType          string               `json:"content_type,omitempty"`
	TimeoutMS            int                  `json:"timeout_ms,omitempty"`
	FollowRedirects      *bool                `json:"follow_redirects,omitempty"`
	InsecureSkipVerify   *bool                `json:"insecure_skip_verify,omitempty"`
	ExpectStatus         []int                `json:"expect_status,omitempty"`
	ExpectStatusMin      int                  `json:"expect_status_min,omitempty"`
	ExpectStatusMax      int                  `json:"expect_status_max,omitempty"`
	ExpectHeaders        map[string]string    `json:"expect_headers,omitempty"`
	ExpectHeaderContains map[string]string    `json:"expect_header_contains,omitempty"`
	ExpectBodyContains   string               `json:"expect_body_contains,omitempty"`
	ExpectJSONFields     []JSONFieldAssertion `json:"expect_json_fields,omitempty"`
	WarnMS               *float64             `json:"warn_ms,omitempty"`
	CritMS               *float64             `json:"crit_ms,omitempty"`
	MinCertDaysWarn      *int                 `json:"min_cert_days_warn,omitempty"`
	MinCertDaysCrit      *int                 `json:"min_cert_days_crit,omitempty"`
	ExtractHeaders       []HeaderExtractor    `json:"extract_headers,omitempty"`
	ExtractCookies       []CookieExtractor    `json:"extract_cookies,omitempty"`
	ExtractJSONFields    []JSONFieldExtractor `json:"extract_json_fields,omitempty"`
}

// JSONFieldAssertion validates a JSON response field against an expected typed value.
type JSONFieldAssertion struct {
	Pointer   string `json:"pointer"`
	Expected  string `json:"expected,omitempty"`
	ValueType string `json:"value_type,omitempty"`
}

// HeaderExtractor captures a response header into an ephemeral journey variable.
type HeaderExtractor struct {
	Header string `json:"header"`
	Var    string `json:"var"`
}

// CookieExtractor captures an accepted response cookie into an ephemeral journey variable.
type CookieExtractor struct {
	Cookie string `json:"cookie"`
	Var    string `json:"var"`
}

// JSONFieldExtractor captures a scalar JSON field into an ephemeral journey variable.
type JSONFieldExtractor struct {
	Pointer string `json:"pointer"`
	Var     string `json:"var"`
}

type pluginInputsEnvelope struct {
	Schema   string            `json:"schema"`
	Template json.RawMessage   `json:"template"`
	Inputs   []json.RawMessage `json:"inputs"`
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		primeTinyGoJSON()

		raw, err := loadRawConfigBytes()
		if err != nil {
			return sdk.Unknown("Configuration error: failed to load config: " + err.Error()), nil
		}

		cfg, err := decodeConfig(raw)
		if err != nil {
			return sdk.Unknown("Configuration error: invalid JSON config: " + err.Error()), nil
		}

		return runSyntheticJourney(cfg), nil
	})
}

// primeTinyGoJSON registers reflection metadata for encoding/json when TinyGo
// compiles WASI modules with _start suppressed.
func primeTinyGoJSON() {
	var env pluginInputsEnvelope
	_ = json.Unmarshal([]byte(`{"schema":"serviceradar.plugin_inputs.v1","template":{},"inputs":[{}]}`), &env)

	var cfg Config
	_ = json.Unmarshal([]byte(`{
		"journey_name":"prime",
		"web_property_id":"wp-prime",
		"device_id":"dev-prime",
		"target_ip":"192.0.2.1",
		"emit_telemetry":true,
		"timeout_ms":5000,
		"follow_redirects":true,
		"insecure_skip_verify":false,
		"warn_ms":100,
		"crit_ms":500,
		"min_cert_days_warn":14,
		"min_cert_days_crit":7,
		"api_token_secret_ref":"ref",
		"api_token":"tok",
		"username":"user",
		"password_secret_ref":"ref",
		"password":"pw",
		"steps":[{
			"name":"step-1",
			"method":"POST",
			"url":"https://example.test/login",
			"headers":{"X-Test":"1"},
			"body":"{}",
			"content_type":"application/json",
			"timeout_ms":5000,
			"follow_redirects":false,
			"insecure_skip_verify":false,
			"expect_status":[200,302],
			"expect_status_min":200,
			"expect_status_max":299,
			"expect_headers":{"Content-Type":"application/json"},
			"expect_header_contains":{"Cache-Control":"no-store"},
			"expect_body_contains":"ok",
			"expect_json_fields":[{"pointer":"/ok","expected":"true","value_type":"boolean"}],
			"warn_ms":100,
			"crit_ms":500,
			"min_cert_days_warn":14,
			"min_cert_days_crit":7,
			"extract_headers":[{"header":"X-Req-ID","var":"req_id"}],
			"extract_cookies":[{"cookie":"sid","var":"sid"}],
			"extract_json_fields":[{"pointer":"/csrf","var":"csrf"}]
		}]
	}`), &cfg)
	_, _ = json.Marshal(cfg)
}

func loadRawConfigBytes() (json.RawMessage, error) {
	var raw json.RawMessage
	if err := sdk.LoadConfig(&raw); err != nil {
		return nil, err
	}
	return raw, nil
}

func decodeConfig(raw []byte) (Config, error) {
	var cfg Config
	if strings.TrimSpace(string(raw)) == "" {
		return cfg, nil
	}

	if looksLikePluginInputs(raw) {
		var env pluginInputsEnvelope
		if err := json.Unmarshal(raw, &env); err != nil {
			return cfg, err
		}
		if len(env.Template) == 0 {
			return cfg, nil
		}
		if err := json.Unmarshal(env.Template, &cfg); err != nil {
			return cfg, err
		}
		return cfg, nil
	}

	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func looksLikePluginInputs(raw []byte) bool {
	var probe struct {
		Schema string            `json:"schema"`
		Inputs []json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false
	}
	return strings.TrimSpace(probe.Schema) == sdk.PluginInputsSchemaV1 || len(probe.Inputs) > 0
}

func runSyntheticJourney(cfg Config) *sdk.Result {
	journey, err := buildJourney(cfg)
	if err != nil {
		return scrubResultSecrets(sdk.Unknown("Configuration error: "+err.Error()), cfg)
	}

	res, err := journey.Run()
	if err != nil {
		msg := scrubText(err.Error(), configSecrets(cfg))
		return scrubResultSecrets(sdk.Critical("Journey execution failed: "+msg), cfg)
	}
	if res == nil {
		return scrubResultSecrets(sdk.Unknown("Journey execution returned no result"), cfg)
	}
	return scrubResultSecrets(res, cfg)
}

func buildJourney(cfg Config) (*sdk.Journey, error) {
	steps := cfg.Steps
	if len(steps) == 0 {
		return nil, fmt.Errorf("steps is required")
	}
	if len(steps) > maxJourneySteps {
		return nil, fmt.Errorf("steps exceeds maximum allowed (%d > %d)", len(steps), maxJourneySteps)
	}

	journeyName := strings.TrimSpace(cfg.JourneyName)
	if journeyName == "" {
		journeyName = defaultJourneyName
	}

	journey := sdk.NewJourney(journeyName)
	if id := strings.TrimSpace(cfg.WebPropertyID); id != "" {
		journey.WithWebPropertyID(id)
	}
	if devID := strings.TrimSpace(cfg.DeviceID); devID != "" {
		journey.WithDeviceID(devID)
	}
	if ip := strings.TrimSpace(cfg.TargetIP); ip != "" {
		journey.WithTargetDeviceIP(ip)
	}
	emitTelemetry := true
	if cfg.EmitTelemetry != nil {
		emitTelemetry = *cfg.EmitTelemetry
	}
	journey.WithTelemetry(emitTelemetry)

	for idx, sc := range steps {
		stepName := strings.TrimSpace(sc.Name)
		if stepName == "" {
			stepName = fmt.Sprintf("step-%d", idx+1)
		}

		rawURL := strings.TrimSpace(sc.URL)
		if rawURL == "" {
			return nil, fmt.Errorf("step %q requires a url", stepName)
		}
		if _, err := expandCredentialPlaceholders(rawURL, cfg, true); err != nil {
			return nil, fmt.Errorf("step %q: %w", stepName, err)
		}

		method := strings.ToUpper(strings.TrimSpace(sc.Method))
		if method == "" {
			method = http.MethodGet
		}

		step := journey.Step(stepName, method, rawURL)

		timeoutMS := sc.TimeoutMS
		if timeoutMS <= 0 {
			timeoutMS = cfg.TimeoutMS
		}
		if timeoutMS <= 0 {
			timeoutMS = defaultTimeoutMS
		}
		step.WithTimeoutMS(timeoutMS)

		if sc.FollowRedirects != nil {
			step.WithFollowRedirects(*sc.FollowRedirects)
		} else if cfg.FollowRedirects != nil {
			step.WithFollowRedirects(*cfg.FollowRedirects)
		}

		if sc.InsecureSkipVerify != nil {
			step.WithInsecureTLS(*sc.InsecureSkipVerify)
		} else if cfg.InsecureSkipVerify {
			step.WithInsecureTLS(true)
		}

		hasContentType := false
		if len(sc.Headers) > 0 {
			keys := sortedMapKeys(sc.Headers)
			for _, k := range keys {
				if strings.EqualFold(strings.TrimSpace(k), "Content-Type") {
					hasContentType = true
				}
				val, err := expandCredentialPlaceholders(sc.Headers[k], cfg, false)
				if err != nil {
					return nil, fmt.Errorf("step %q header %q: %w", stepName, k, err)
				}
				step.WithHeader(k, val)
			}
		}
		if ct := strings.TrimSpace(sc.ContentType); ct != "" && !hasContentType {
			step.WithHeader("Content-Type", ct)
		}

		if sc.Body != "" {
			body, err := expandCredentialPlaceholders(sc.Body, cfg, false)
			if err != nil {
				return nil, fmt.Errorf("step %q body: %w", stepName, err)
			}
			step.WithTextBody(body)
		}

		if len(sc.ExpectStatus) > 0 {
			for _, code := range sc.ExpectStatus {
				if code < 100 || code > 599 {
					return nil, fmt.Errorf("step %q invalid expect_status %d", stepName, code)
				}
			}
			step.ExpectStatus(sc.ExpectStatus...)
		}

		if sc.ExpectStatusMin != 0 || sc.ExpectStatusMax != 0 {
			if sc.ExpectStatusMin < 100 || sc.ExpectStatusMax > 599 || sc.ExpectStatusMin > sc.ExpectStatusMax {
				return nil, fmt.Errorf("step %q invalid expect_status range [%d, %d]", stepName, sc.ExpectStatusMin, sc.ExpectStatusMax)
			}
			step.ExpectStatusRange(sc.ExpectStatusMin, sc.ExpectStatusMax)
		}

		if len(sc.ExpectHeaders) > 0 {
			for _, k := range sortedMapKeys(sc.ExpectHeaders) {
				step.ExpectHeader(k, sc.ExpectHeaders[k])
			}
		}

		if len(sc.ExpectHeaderContains) > 0 {
			for _, k := range sortedMapKeys(sc.ExpectHeaderContains) {
				step.ExpectHeaderContains(k, sc.ExpectHeaderContains[k])
			}
		}

		if sc.ExpectBodyContains != "" {
			step.ExpectBodyContains(sc.ExpectBodyContains)
		}

		for _, jf := range sc.ExpectJSONFields {
			pointer := strings.TrimSpace(jf.Pointer)
			if pointer == "" {
				return nil, fmt.Errorf("step %q expect_json_fields requires pointer", stepName)
			}
			expected, err := parseExpectedJSONValue(jf.Expected, jf.ValueType)
			if err != nil {
				return nil, fmt.Errorf("step %q expect_json_fields %q: %w", stepName, pointer, err)
			}
			step.ExpectJSONField(pointer, expected)
		}

		warnMS, critMS, hasDurationThreshold, err := resolveDurationThresholds(sc.WarnMS, sc.CritMS, cfg.WarnMS, cfg.CritMS)
		if err != nil {
			return nil, fmt.Errorf("step %q: %w", stepName, err)
		}
		if hasDurationThreshold {
			step.ExpectMaxDuration(warnMS, critMS)
		}

		warnDays, critDays, hasCertThreshold, err := resolveCertDayThresholds(sc.MinCertDaysWarn, sc.MinCertDaysCrit, cfg.MinCertDaysWarn, cfg.MinCertDaysCrit)
		if err != nil {
			return nil, fmt.Errorf("step %q: %w", stepName, err)
		}
		if hasCertThreshold {
			step.ExpectMinCertDays(warnDays, critDays)
		}

		for _, ex := range sc.ExtractHeaders {
			header := strings.TrimSpace(ex.Header)
			varName := strings.TrimSpace(ex.Var)
			if header == "" || varName == "" {
				return nil, fmt.Errorf("step %q extract_headers requires header and var", stepName)
			}
			step.ExtractHeader(header, varName)
		}

		for _, ex := range sc.ExtractCookies {
			cookie := strings.TrimSpace(ex.Cookie)
			varName := strings.TrimSpace(ex.Var)
			if cookie == "" || varName == "" {
				return nil, fmt.Errorf("step %q extract_cookies requires cookie and var", stepName)
			}
			step.ExtractCookie(cookie, varName)
		}

		for _, ex := range sc.ExtractJSONFields {
			pointer := strings.TrimSpace(ex.Pointer)
			varName := strings.TrimSpace(ex.Var)
			if pointer == "" || varName == "" {
				return nil, fmt.Errorf("step %q extract_json_fields requires pointer and var", stepName)
			}
			step.ExtractJSONField(pointer, varName)
		}
	}

	return journey, nil
}

func resolveDurationThresholds(stepWarn, stepCrit, defaultWarn, defaultCrit *float64) (float64, float64, bool, error) {
	warn := 0.0
	crit := 0.0
	set := false

	if stepWarn != nil {
		warn = *stepWarn
		set = true
	} else if defaultWarn != nil {
		warn = *defaultWarn
		set = true
	}

	if stepCrit != nil {
		crit = *stepCrit
		set = true
	} else if defaultCrit != nil {
		crit = *defaultCrit
		set = true
	}

	if warn < 0 || crit < 0 {
		return 0, 0, false, fmt.Errorf("latency thresholds must be non-negative")
	}
	if !set || (warn == 0 && crit == 0) {
		return 0, 0, false, nil
	}
	return warn, crit, true, nil
}

func resolveCertDayThresholds(stepWarn, stepCrit, defaultWarn, defaultCrit *int) (int, int, bool, error) {
	warn := -1
	crit := -1

	if stepWarn != nil {
		warn = *stepWarn
	} else if defaultWarn != nil {
		warn = *defaultWarn
	}

	if stepCrit != nil {
		crit = *stepCrit
	} else if defaultCrit != nil {
		crit = *defaultCrit
	}

	if stepWarn != nil && *stepWarn < 0 || defaultWarn != nil && *defaultWarn < 0 {
		return -1, -1, false, fmt.Errorf("min_cert_days_warn must be non-negative")
	}
	if stepCrit != nil && *stepCrit < 0 || defaultCrit != nil && *defaultCrit < 0 {
		return -1, -1, false, fmt.Errorf("min_cert_days_crit must be non-negative")
	}
	if warn < 0 && crit < 0 {
		return -1, -1, false, nil
	}
	return warn, crit, true, nil
}

func parseExpectedJSONValue(expected, valueType string) (any, error) {
	kind := strings.ToLower(strings.TrimSpace(valueType))
	if kind == "" {
		kind = "string"
	}

	switch kind {
	case "string":
		return expected, nil
	case "null":
		trimmed := strings.TrimSpace(expected)
		if trimmed != "" && trimmed != "null" {
			return nil, fmt.Errorf("null value_type expects empty or \"null\" string, got %q", expected)
		}
		return nil, nil
	case "boolean":
		b, err := strconv.ParseBool(strings.TrimSpace(expected))
		if err != nil {
			return nil, fmt.Errorf("invalid boolean expected value %q", expected)
		}
		return b, nil
	case "number":
		trimmed := strings.TrimSpace(expected)
		if trimmed == "" {
			return nil, fmt.Errorf("numeric expected value cannot be empty")
		}
		if _, err := strconv.ParseInt(trimmed, 10, 64); err != nil {
			f, floatErr := strconv.ParseFloat(trimmed, 64)
			if floatErr != nil || math.IsNaN(f) || math.IsInf(f, 0) {
				return nil, fmt.Errorf("invalid numeric expected value %q", expected)
			}
		}
		return json.Number(trimmed), nil
	default:
		return nil, fmt.Errorf("unsupported value_type %q", valueType)
	}
}

func expandCredentialPlaceholders(input string, cfg Config, inURL bool) (string, error) {
	if !strings.Contains(input, "{{") {
		return input, nil
	}

	var out strings.Builder
	rest := input
	for {
		start := strings.Index(rest, "{{")
		if start < 0 {
			out.WriteString(rest)
			break
		}
		out.WriteString(rest[:start])
		afterStart := rest[start+2:]
		end := strings.Index(afterStart, "}}")
		if end < 0 {
			out.WriteString(rest[start:])
			break
		}

		rawToken := rest[start : start+2+end+2]
		varName := strings.TrimSpace(afterStart[:end])
		switch varName {
		case "api_token":
			if inURL {
				return "", fmt.Errorf("credential placeholder {{%s}} is not allowed in URL", varName)
			}
			if cfg.APIToken == "" {
				return "", fmt.Errorf("credential {{api_token}} referenced but api_token is not configured")
			}
			out.WriteString(cfg.APIToken)
		case "username":
			if inURL {
				return "", fmt.Errorf("credential placeholder {{%s}} is not allowed in URL", varName)
			}
			if cfg.Username == "" {
				return "", fmt.Errorf("credential {{username}} referenced but username is not configured")
			}
			out.WriteString(cfg.Username)
		case "password":
			if inURL {
				return "", fmt.Errorf("credential placeholder {{%s}} is not allowed in URL", varName)
			}
			if cfg.Password == "" {
				return "", fmt.Errorf("credential {{password}} referenced but password is not configured")
			}
			out.WriteString(cfg.Password)
		default:
			// Leave non-credential {{var}} placeholders for sdk.Journey step-time extraction.
			out.WriteString(rawToken)
		}

		rest = afterStart[end+2:]
	}

	return out.String(), nil
}

func sortedMapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func configSecrets(cfg Config) []string {
	seen := make(map[string]struct{}, 2)
	var secrets []string
	for _, candidate := range []string{cfg.APIToken, cfg.Password} {
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		secrets = append(secrets, candidate)
	}
	sort.Slice(secrets, func(i, j int) bool {
		if len(secrets[i]) != len(secrets[j]) {
			return len(secrets[i]) > len(secrets[j])
		}
		return secrets[i] < secrets[j]
	})
	return secrets
}

func scrubText(text string, secrets []string) string {
	for _, secret := range secrets {
		if secret != "" && strings.Contains(text, secret) {
			text = strings.ReplaceAll(text, secret, redactedSecret)
		}
	}
	return text
}

func scrubAny(v any, secrets []string) any {
	switch typed := v.(type) {
	case string:
		return scrubText(typed, secrets)
	case []string:
		for i := range typed {
			typed[i] = scrubText(typed[i], secrets)
		}
		return typed
	case []any:
		for i := range typed {
			typed[i] = scrubAny(typed[i], secrets)
		}
		return typed
	case map[string]string:
		for k, val := range typed {
			typed[k] = scrubText(val, secrets)
		}
		return typed
	case map[string]any:
		for k, val := range typed {
			typed[k] = scrubAny(val, secrets)
		}
		return typed
	default:
		return v
	}
}

func scrubResultSecrets(res *sdk.Result, cfg Config) *sdk.Result {
	if res == nil {
		return nil
	}
	secrets := configSecrets(cfg)
	if len(secrets) == 0 {
		return res
	}

	res.Summary = scrubText(res.Summary, secrets)
	res.Details = scrubText(res.Details, secrets)
	res.Perfdata = scrubText(res.Perfdata, secrets)

	for k, v := range res.Labels {
		res.Labels[k] = scrubText(v, secrets)
	}
	for i := range res.Events {
		res.Events[i].Message = scrubText(res.Events[i].Message, secrets)
		res.Events[i].StatusDetail = scrubText(res.Events[i].StatusDetail, secrets)
		res.Events[i].RawData = scrubText(res.Events[i].RawData, secrets)
	}
	for i := range res.Display {
		res.Display[i].Label = scrubText(res.Display[i].Label, secrets)
		res.Display[i].Value = scrubText(res.Display[i].Value, secrets)
		if res.Display[i].Data != nil {
			res.Display[i].Data = scrubAny(res.Display[i].Data, secrets).(map[string]any)
		}
	}
	return res
}

func main() {}
