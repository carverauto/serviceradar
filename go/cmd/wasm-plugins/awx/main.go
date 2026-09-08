// awx is the AWX/AAP network-bridge WASM plugin for ServiceRadar.
//
// The plugin is invoked by the agent runtime in two shapes:
//
//   - On-demand: Elixir's AwxClient dispatches a CommandRequest with a verb
//     (e.g. "awx.ping", "awx.launch_job") via AgentCommandBus. The agent
//     translates the request payload into the plugin's config; the plugin
//     dispatches on `cfg.Verb`, makes one HTTP call (or a paginated walk) to
//     AWX, and returns a structured payload in the result's Details field.
//   - Scheduled: a periodic `inventory_sync` assignment walks AWX inventories
//     and emits a DeviceDiscovery aggregate; the existing agent → gateway →
//     DIRE pipeline ingests it.
//
// The plugin holds no per-controller state. It sees controller URLs and a
// non-secret token sentinel. The trusted agent HTTP host injects the real
// bearer only after it authorizes the exact request against an on-demand grant
// or a scheduled inventory-origin binding. See openspec change
// `add-ansible-integration` for the full design.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// awxHTTP is package-level so tests can swap it for a fake.
var awxHTTP httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

// errAWXRequestFailed is the only error allowed to cross the controller HTTP
// boundary. The underlying client error and response text are never retained
// in a plugin result.
var errAWXRequestFailed = fmt.Errorf("AWX request failed")

type httpClient interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

// Config is what the agent runtime hands to the plugin via get_config.
//
// The agent populates `APIToken` with a non-secret sentinel. The plugin never
// receives controller bearer material; the trusted host overwrites the
// sentinel Authorization header only for an authorized HTTP request.
type Config struct {
	// BaseURL is the AWX/AAP base URL, e.g. https://awx.internal.example.com.
	BaseURL string `json:"base_url"`

	// APIToken is a non-secret sentinel sent in the Authorization header and
	// replaced by the trusted agent host after request authorization.
	APIToken string `json:"api_token"`

	// Verb selects which REST verb to execute. When empty, the plugin
	// behaves as a default-no-op so a missing assignment doesn't error.
	Verb string `json:"verb,omitempty"`

	// Args carries verb-specific arguments. Each verb pulls what it needs.
	Args map[string]any `json:"args,omitempty"`

	// TimeoutMS bounds individual HTTP calls. Defaults to 15s.
	TimeoutMS int `json:"timeout_ms,omitempty"`

	// InsecureSkipVerify allows self-signed AWX deployments. Off by default.
	InsecureSkipVerify bool `json:"insecure_skip_verify,omitempty"`
}

const (
	defaultTimeoutMS                   = 15_000
	maxProjectedResultByteCount        = 3 * 1024 * 1024
	awxInventoryHostCredentialSentinel = "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__"
)

//export run_check
func run_check() {
	primeTinyGoJSON()

	_ = sdk.Execute(func() (*sdk.Result, error) {
		var cfg Config
		if err := sdk.LoadConfig(&cfg); err != nil {
			return sdk.Unknown("AWX configuration could not be loaded"), nil
		}

		if err := validateConfig(cfg); err != nil {
			return sdk.Unknown("AWX configuration invalid: " + err.Error()), nil
		}

		return dispatch(cfg), nil
	})
}

func validateConfig(cfg Config) error {
	if strings.TrimSpace(cfg.BaseURL) == "" {
		return fmt.Errorf("base_url is required")
	}
	if strings.TrimSpace(cfg.APIToken) == "" {
		return fmt.Errorf("api_token is required (resolved from credential broker grant)")
	}
	return nil
}

// dispatch routes on cfg.Verb. Unknown / unimplemented verbs return a
// CRITICAL result so the caller's typed error path triggers cleanly.
func dispatch(cfg Config) *sdk.Result {
	verb := cfg.Verb
	if verb == "" {
		// No verb means the plugin was invoked without a CommandRequest
		// (e.g. a probe). Treat as a ping.
		verb = "awx.ping"
	}

	var result *sdk.Result

	switch verb {
	case "awx.ping":
		result = runPing(cfg)
	case "awx.list_inventories":
		result = runListInventories(cfg)
	case "awx.list_hosts":
		result = runListHosts(cfg)
	case "awx.list_inventory_groups":
		result = runListInventoryGroups(cfg)
	case "awx.list_projects":
		result = runListProjects(cfg)
	case "awx.list_templates":
		result = runListTemplates(cfg)
	case "awx.fetch_template":
		result = runFetchTemplate(cfg)
	case "awx.fetch_launch_preflight":
		result = runFetchLaunchPreflight(cfg)
	case "awx.current_user":
		result = runCurrentUser(cfg)
	case "awx.launch_job":
		result = runLaunchJob(cfg)
	case "awx.create_callback_credential":
		result = runCreateCallbackCredential(cfg)
	case "awx.fetch_callback_credential":
		result = runFetchCallbackCredential(cfg)
	case "awx.verify_callback_credential":
		result = runVerifyCallbackCredential(cfg)
	case "awx.list_callback_credentials":
		result = runListCallbackCredentials(cfg)
	case "awx.delete_callback_credential":
		result = runDeleteCallbackCredential(cfg)
	case "awx.fetch_job":
		result = runFetchJob(cfg)
	case "awx.list_recent_jobs":
		result = runListRecentJobs(cfg)
	case "awx.fetch_job_host_summaries":
		result = runFetchJobHostSummaries(cfg)
	case "awx.cancel_job":
		result = runCancelJob(cfg)
	case "awx.fetch_events_for_jobs":
		result = runFetchEventsForJobs(cfg)
	default:
		return errorResult("awx.invalid", fmt.Errorf("unknown AWX command"))
	}

	return enforceProjectedResultCap(verb, result)
}

// The gateway accepts a larger, still-bounded envelope for protected AWX
// results than for generic agent commands. Enforce the same byte limit at the
// source so an otherwise valid controller projection cannot be truncated or
// transformed only after it crosses the edge trust boundary.
func enforceProjectedResultCap(verb string, result *sdk.Result) *sdk.Result {
	if result != nil && len(result.Details) > maxProjectedResultByteCount {
		return errorResult(verb, fmt.Errorf("AWX projected result exceeds byte cap"))
	}
	return result
}

const (
	callbackCredentialInputSentinel   = "__SERVICERADAR_CALLBACK_CREDENTIAL_INPUT__"
	callbackCredentialDescription     = "ServiceRadar ephemeral automation callback credential"
	callbackCredentialContractSchema  = "serviceradar.awx_callback_credential_type"
	callbackCredentialContractVersion = 1
	maxCallbackCredentialNameBytes    = 128
)

var callbackCredentialInputKeys = [...]string{
	"callback_url",
	"callback_grant",
	"callback_idempotency_key",
	"callback_allowed_origin",
	"callback_manifest_sha256",
	"scm_revision",
	"content_sha256",
	"callback_phase",
	"callback_operation",
	"callback_state",
}

// Allowlists are explicit switch predicates, not map[string]struct{} membership.
// TinyGo has failed closed on package-level string maps when keys come from
// JSON-unmarshaled map[string]any, which blocked every launch/list_recent_jobs
// command before any AWX HTTP call (no credential grant resolution).

func allowedCreateCallbackCredentialArg(key string) bool {
	switch key {
	case "credential_type_id", "organization_id", "credential_name", "injector_sha256":
		return true
	default:
		return false
	}
}

func allowedFetchCallbackCredentialArg(key string) bool {
	switch key {
	case "credential_type_id", "organization_id", "credential_name":
		return true
	default:
		return false
	}
}

func allowedVerifyCallbackCredentialArg(key string) bool {
	switch key {
	case "credential_id", "credential_type_id", "organization_id", "credential_name":
		return true
	default:
		return false
	}
}

func allowedListCallbackCredentialArg(key string) bool {
	switch key {
	case "credential_type_id", "organization_id", "credential_name", "max_credentials":
		return true
	default:
		return false
	}
}

func allowedListRecentJobArg(key string) bool {
	switch key {
	case "template_id", "inventory_id", "created_by_id", "created_after", "page_size", "max_candidates":
		return true
	default:
		return false
	}
}

func allowedDeleteCallbackCredentialArg(key string) bool {
	switch key {
	case "credential_id", "credential_type_id", "organization_id", "credential_name":
		return true
	default:
		return false
	}
}

func allowedLaunchArg(key string) bool {
	switch key {
	case "template_id",
		"extra_vars",
		"host_limit",
		"inventory_id",
		"credential_ids",
		"execution_environment_id",
		"job_type",
		"diff_mode",
		"verbosity",
		"forks",
		"job_slice_count",
		"timeout",
		"job_tags",
		"skip_tags",
		"labels",
		"instance_group_ids":
		return true
	default:
		return false
	}
}

type awxCallbackCredentialSummary struct {
	ID             int    `json:"id"`
	Name           string `json:"name"`
	CredentialType int    `json:"credential_type"`
	Organization   int    `json:"organization"`
}

// runCreateCallbackCredential creates exactly one reviewed ephemeral AWX
// custom credential. The Wasm module deliberately sends sentinel input values;
// the selected agent's trusted HTTP host boundary replaces them from a
// single-resolution, memory-only launch envelope. A missing host-side input
// therefore cannot degrade into a plaintext command/config fallback.
func runCreateCallbackCredential(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedCreateCallbackCredentialArg); err != nil {
		return errorResult("awx.create_callback_credential", err)
	}

	credentialTypeID, ok := positiveArgID(cfg.Args, "credential_type_id")
	if !ok {
		return errorResult("awx.create_callback_credential", fmt.Errorf("args.credential_type_id is required"))
	}
	organizationID, ok := positiveArgID(cfg.Args, "organization_id")
	if !ok {
		return errorResult("awx.create_callback_credential", fmt.Errorf("args.organization_id is required"))
	}
	credentialName, ok := boundedCallbackCredentialName(cfg.Args)
	if !ok {
		return errorResult("awx.create_callback_credential", fmt.Errorf("args.credential_name is invalid"))
	}
	injectorSHA256, ok := argString(cfg.Args, "injector_sha256")
	if !ok || !lowerHexString(injectorSHA256, 64) {
		return errorResult("awx.create_callback_credential", fmt.Errorf("args.injector_sha256 is invalid"))
	}
	if err := verifyCallbackCredentialType(cfg, credentialTypeID, injectorSHA256); err != nil {
		return errorResult("awx.create_callback_credential", err)
	}

	existing, err := preflightCallbackCredential(cfg, credentialName, credentialTypeID, organizationID)
	if err != nil {
		return errorResult("awx.create_callback_credential", err)
	}
	if existing != nil {
		return callbackCredentialConflictResult(*existing)
	}

	inputs := make(map[string]string, len(callbackCredentialInputKeys))
	for _, key := range callbackCredentialInputKeys {
		inputs[key] = callbackCredentialInputSentinel
	}

	body := map[string]any{
		"name":            credentialName,
		"description":     callbackCredentialDescription,
		"credential_type": credentialTypeID,
		"organization":    organizationID,
		"inputs":          inputs,
	}
	resp, err := postJSON(cfg, "/api/v2/credentials/", body)
	if err != nil {
		return errorResult("awx.create_callback_credential", err)
	}

	credential, err := decodeAndVerifyCallbackCredential(
		resp.Body,
		0,
		credentialName,
		credentialTypeID,
		organizationID,
	)
	if err != nil {
		return errorResult("awx.create_callback_credential", err)
	}

	payload := map[string]any{
		"verb":               "awx.create_callback_credential",
		"ok":                 true,
		"credential_id":      credential.ID,
		"credential_type_id": credential.CredentialType,
		"organization_id":    credential.Organization,
		"credential_name":    credential.Name,
		"injector_sha256":    injectorSHA256,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("created ephemeral callback credential %d", credential.ID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.create_callback_credential")
}

// runFetchCallbackCredential performs read-only reconciliation of the
// deterministic ephemeral credential after an ambiguous create transport.
// It never creates, updates, or deletes a credential.
func runFetchCallbackCredential(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedFetchCallbackCredentialArg); err != nil {
		return errorResult("awx.fetch_callback_credential", err)
	}

	credentialTypeID, ok := positiveArgID(cfg.Args, "credential_type_id")
	if !ok {
		return errorResult("awx.fetch_callback_credential", fmt.Errorf("args.credential_type_id is required"))
	}
	organizationID, ok := positiveArgID(cfg.Args, "organization_id")
	if !ok {
		return errorResult("awx.fetch_callback_credential", fmt.Errorf("args.organization_id is required"))
	}
	credentialName, ok := boundedCallbackCredentialName(cfg.Args)
	if !ok {
		return errorResult("awx.fetch_callback_credential", fmt.Errorf("args.credential_name is invalid"))
	}

	credential, err := preflightCallbackCredential(
		cfg,
		credentialName,
		credentialTypeID,
		organizationID,
	)
	if err != nil {
		return errorResult("awx.fetch_callback_credential", err)
	}

	payload := map[string]any{
		"verb":               "awx.fetch_callback_credential",
		"ok":                 true,
		"found":              credential != nil,
		"credential_type_id": credentialTypeID,
		"organization_id":    organizationID,
		"credential_name":    credentialName,
	}
	if credential != nil {
		payload["credential_id"] = credential.ID
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok("reconciled ephemeral callback credential").
		WithDetails(string(out)).
		WithLabel("verb", "awx.fetch_callback_credential")
}

const maxCallbackCredentialLookupResults = 5_000

// runVerifyCallbackCredential proves one server-selected credential ID against
// the exact deterministic callback scope. Unlike the reconciliation list verb,
// this path never treats absence as success and never accepts co-reported
// selector fields in place of a direct controller GET by ID.
func runVerifyCallbackCredential(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedVerifyCallbackCredentialArg); err != nil {
		return errorResult("awx.verify_callback_credential", err)
	}

	credentialID, ok := positiveArgID(cfg.Args, "credential_id")
	if !ok {
		return errorResult("awx.verify_callback_credential", fmt.Errorf("args.credential_id is required"))
	}
	credentialTypeID, ok := positiveArgID(cfg.Args, "credential_type_id")
	if !ok {
		return errorResult("awx.verify_callback_credential", fmt.Errorf("args.credential_type_id is required"))
	}
	organizationID, ok := positiveArgID(cfg.Args, "organization_id")
	if !ok {
		return errorResult("awx.verify_callback_credential", fmt.Errorf("args.organization_id is required"))
	}
	credentialName, ok := boundedCallbackCredentialName(cfg.Args)
	if !ok {
		return errorResult("awx.verify_callback_credential", fmt.Errorf("args.credential_name is invalid"))
	}

	resp, err := getJSON(cfg, fmt.Sprintf("/api/v2/credentials/%d/", credentialID))
	if err != nil {
		return errorResult("awx.verify_callback_credential", err)
	}
	credential, err := decodeAndVerifyCallbackCredential(
		resp.Body,
		credentialID,
		credentialName,
		credentialTypeID,
		organizationID,
	)
	if err != nil {
		return errorResult("awx.verify_callback_credential", err)
	}

	payload := map[string]any{
		"verb":          "awx.verify_callback_credential",
		"ok":            true,
		"credential_id": credentialID,
		"credential":    callbackCredentialProjection(credential),
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("verified callback credential %d", credentialID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.verify_callback_credential")
}

// runListCallbackCredentials returns the complete, bounded set matching the
// exact deterministic callback scope. Ambiguity is data for trusted cleanup,
// not a reason to discard controller-observed IDs; an incomplete or drifting
// page set still fails closed.
func runListCallbackCredentials(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedListCallbackCredentialArg); err != nil {
		return errorResult("awx.list_callback_credentials", err)
	}

	credentialTypeID, ok := positiveArgID(cfg.Args, "credential_type_id")
	if !ok {
		return errorResult("awx.list_callback_credentials", fmt.Errorf("args.credential_type_id is required"))
	}
	organizationID, ok := positiveArgID(cfg.Args, "organization_id")
	if !ok {
		return errorResult("awx.list_callback_credentials", fmt.Errorf("args.organization_id is required"))
	}
	credentialName, ok := boundedCallbackCredentialName(cfg.Args)
	if !ok {
		return errorResult("awx.list_callback_credentials", fmt.Errorf("args.credential_name is invalid"))
	}
	maxCredentials, ok := argInt(cfg.Args, "max_credentials")
	if !ok || maxCredentials <= 0 || maxCredentials > maxCallbackCredentialLookupResults {
		return errorResult(
			"awx.list_callback_credentials",
			fmt.Errorf("args.max_credentials must be an integer between 1 and %d", maxCallbackCredentialLookupResults),
		)
	}

	query := url.Values{}
	query.Set("name", credentialName)
	query.Set("credential_type", strconv.Itoa(credentialTypeID))
	query.Set("organization", strconv.Itoa(organizationID))
	query.Set("order_by", "id")
	query.Set("page_size", strconv.Itoa(awxPageSize))
	rawCredentials, total, err := listAWXPathBounded(
		cfg,
		"/api/v2/credentials/?"+query.Encode(),
		maxCredentials,
	)
	if err != nil {
		return errorResult("awx.list_callback_credentials", err)
	}

	credentials := make([]map[string]any, 0, len(rawCredentials))
	previousID := 0
	for _, rawCredential := range rawCredentials {
		credential, err := decodeAndVerifyCallbackCredential(
			rawCredential,
			0,
			credentialName,
			credentialTypeID,
			organizationID,
		)
		if err != nil {
			return errorResult("awx.list_callback_credentials", err)
		}
		if credential.ID <= previousID {
			return errorResult(
				"awx.list_callback_credentials",
				fmt.Errorf("AWX callback credential pagination is not strictly ordered"),
			)
		}
		previousID = credential.ID
		credentials = append(credentials, callbackCredentialProjection(credential))
	}

	payload := map[string]any{
		"verb":               "awx.list_callback_credentials",
		"ok":                 true,
		"credential_type_id": credentialTypeID,
		"organization_id":    organizationID,
		"credential_name":    credentialName,
		"max_credentials":    maxCredentials,
		"count":              total,
		"complete":           true,
		"credentials":        credentials,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("listed %d callback credentials", total)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.list_callback_credentials")
}

func callbackCredentialProjection(credential awxCallbackCredentialSummary) map[string]any {
	return map[string]any{
		"id":                 credential.ID,
		"name":               credential.Name,
		"credential_type_id": credential.CredentialType,
		"organization_id":    credential.Organization,
	}
}

type awxCallbackCredentialTypeField struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Type   string `json:"type"`
	Secret bool   `json:"secret"`
}

type normalizedCallbackCredentialType struct {
	CredentialTypeID int
	Kind             string
	Fields           []awxCallbackCredentialTypeField
	Required         []string
	Environment      map[string]string
}

func verifyCallbackCredentialType(cfg Config, credentialTypeID int, expectedDigest string) error {
	resp, err := getJSON(cfg, fmt.Sprintf("/api/v2/credential_types/%d/", credentialTypeID))
	if err != nil {
		return err
	}
	contract, err := normalizeCallbackCredentialType(resp.Body, credentialTypeID)
	if err != nil {
		return err
	}
	encoded, err := canonicalCallbackCredentialTypeDocument(contract)
	if err != nil {
		return fmt.Errorf("encode callback credential type contract: %w", err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(encoded))
	if digest != expectedDigest {
		return fmt.Errorf("callback credential type injector digest mismatch")
	}
	return nil
}

func normalizeCallbackCredentialType(body []byte, expectedID int) (normalizedCallbackCredentialType, error) {
	var raw struct {
		ID        int             `json:"id"`
		Kind      string          `json:"kind"`
		Managed   bool            `json:"managed"`
		Inputs    json.RawMessage `json:"inputs"`
		Injectors json.RawMessage `json:"injectors"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type: %w", err)
	}
	if raw.ID != expectedID || raw.Kind != "cloud" || raw.Managed {
		return normalizedCallbackCredentialType{}, fmt.Errorf("AWX returned an unreviewed callback credential type")
	}

	var inputRoot map[string]json.RawMessage
	if err := json.Unmarshal(raw.Inputs, &inputRoot); err != nil {
		return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type inputs: %w", err)
	}
	if !rawMessageKeysEqual(inputRoot, "fields", "required") {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type input properties are unreviewed")
	}
	var rawFields []json.RawMessage
	var required []string
	if err := json.Unmarshal(inputRoot["fields"], &rawFields); err != nil {
		return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type fields: %w", err)
	}
	if err := json.Unmarshal(inputRoot["required"], &required); err != nil {
		return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type required fields: %w", err)
	}
	if len(rawFields) != len(callbackCredentialInputKeys) || len(required) != len(callbackCredentialInputKeys) {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type inputs do not match the reviewed contract")
	}
	expectedSecret := map[string]bool{
		"callback_grant":           true,
		"callback_idempotency_key": true,
	}
	expectedLabels := expectedCallbackCredentialFieldLabels()
	fields := make([]awxCallbackCredentialTypeField, 0, len(rawFields))
	seenFields := make(map[string]struct{}, len(rawFields))
	for _, rawField := range rawFields {
		var fieldRoot map[string]json.RawMessage
		if err := json.Unmarshal(rawField, &fieldRoot); err != nil ||
			!rawMessageKeysEqual(fieldRoot, "id", "label", "type", "secret") {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type field is unreviewed")
		}
		var field awxCallbackCredentialTypeField
		if err := json.Unmarshal(rawField, &field); err != nil {
			return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type field: %w", err)
		}
		secret := expectedSecret[field.ID]
		if field.Label != expectedLabels[field.ID] ||
			field.Type != "string" || field.Secret != secret {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type field is unreviewed")
		}
		if _, duplicate := seenFields[field.ID]; duplicate {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type contains duplicate fields")
		}
		seenFields[field.ID] = struct{}{}
		fields = append(fields, field)
	}
	for _, key := range callbackCredentialInputKeys {
		if _, present := seenFields[key]; !present {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type is missing field %q", key)
		}
	}
	sort.Slice(fields, func(i, j int) bool { return fields[i].ID < fields[j].ID })
	sort.Strings(required)
	expectedRequired := append([]string(nil), callbackCredentialInputKeys[:]...)
	sort.Strings(expectedRequired)
	if !stringSlicesEqual(required, expectedRequired) {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type required fields are unreviewed")
	}

	var injectorRoot map[string]json.RawMessage
	if err := json.Unmarshal(raw.Injectors, &injectorRoot); err != nil || len(injectorRoot) != 1 {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type injector is unreviewed")
	}
	var environment map[string]string
	if err := json.Unmarshal(injectorRoot["env"], &environment); err != nil ||
		!stringMapsEqual(environment, expectedCallbackCredentialEnvironment()) {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type environment injector is unreviewed")
	}

	return normalizedCallbackCredentialType{
		CredentialTypeID: raw.ID,
		Kind:             raw.Kind,
		Fields:           fields,
		Required:         required,
		Environment:      environment,
	}, nil
}

func rawMessageKeysEqual(values map[string]json.RawMessage, expected ...string) bool {
	if len(values) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, present := values[key]; !present {
			return false
		}
	}
	return true
}

func expectedCallbackCredentialFieldLabels() map[string]string {
	return map[string]string{
		"callback_url":             "Callback URL",
		"callback_grant":           "Callback grant",
		"callback_idempotency_key": "Callback idempotency key",
		"callback_allowed_origin":  "Callback allowed origin",
		"callback_manifest_sha256": "Callback manifest SHA-256",
		"scm_revision":             "SCM revision",
		"content_sha256":           "Content SHA-256",
		"callback_phase":           "Callback phase",
		"callback_operation":       "Callback operation",
		"callback_state":           "Callback state",
	}
}

// canonicalCallbackCredentialTypeDocument serializes the reviewed credential
// type contract independently of Go struct declaration order. The
// language-neutral format is UTF-8, minified JSON with recursively
// lexicographically sorted object keys. Fields and required values are sorted
// lexicographically by input ID before encoding. The document has these exact
// top-level keys: schema, version, credential_type_id, kind, fields, required,
// and environment. Numbers are base-10 JSON integers and strings use standard
// JSON escaping. A fixed byte-and-SHA-256 conformance vector lives in the test
// suite so the Elixir/operator implementation can produce identical bytes.
func canonicalCallbackCredentialTypeDocument(contract normalizedCallbackCredentialType) ([]byte, error) {
	fields := append([]awxCallbackCredentialTypeField(nil), contract.Fields...)
	sort.Slice(fields, func(i, j int) bool { return fields[i].ID < fields[j].ID })
	canonicalFields := make([]map[string]any, 0, len(fields))
	for _, field := range fields {
		canonicalFields = append(canonicalFields, map[string]any{
			"id":     field.ID,
			"secret": field.Secret,
			"type":   field.Type,
		})
	}
	required := append([]string(nil), contract.Required...)
	sort.Strings(required)
	environment := make(map[string]string, len(contract.Environment))
	for key, value := range contract.Environment {
		environment[key] = value
	}

	// encoding/json sorts string map keys recursively. Building this document
	// solely from maps avoids tying the digest to Go struct field order.
	document := map[string]any{
		"schema":             callbackCredentialContractSchema,
		"version":            callbackCredentialContractVersion,
		"credential_type_id": contract.CredentialTypeID,
		"kind":               contract.Kind,
		"fields":             canonicalFields,
		"required":           required,
		"environment":        environment,
	}
	return json.Marshal(document)
}

func expectedCallbackCredentialEnvironment() map[string]string {
	return map[string]string{
		"SERVICERADAR_CALLBACK_URL":             "{{ callback_url }}",
		"SERVICERADAR_CALLBACK_GRANT":           "{{ callback_grant }}",
		"SERVICERADAR_CALLBACK_IDEMPOTENCY_KEY": "{{ callback_idempotency_key }}",
		"SERVICERADAR_CALLBACK_ALLOWED_ORIGIN":  "{{ callback_allowed_origin }}",
		"SERVICERADAR_CALLBACK_MANIFEST_SHA256": "{{ callback_manifest_sha256 }}",
		"SERVICERADAR_SCM_REVISION":             "{{ scm_revision }}",
		"SERVICERADAR_CONTENT_SHA256":           "{{ content_sha256 }}",
		"SERVICERADAR_CALLBACK_PHASE":           "{{ callback_phase }}",
		"SERVICERADAR_CALLBACK_OPERATION":       "{{ callback_operation }}",
		"SERVICERADAR_CALLBACK_STATE":           "{{ callback_state }}",
	}
}

func stringMapsEqual(left, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range right {
		if left[key] != value {
			return false
		}
	}
	return true
}

func stringSlicesEqual(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func lowerHexString(value string, size int) bool {
	if len(value) != size {
		return false
	}
	for _, char := range value {
		if !((char >= 'a' && char <= 'f') || (char >= '0' && char <= '9')) {
			return false
		}
	}
	return true
}

func preflightCallbackCredential(
	cfg Config,
	credentialName string,
	credentialTypeID int,
	organizationID int,
) (*awxCallbackCredentialSummary, error) {
	query := url.Values{}
	query.Set("name", credentialName)
	query.Set("credential_type", strconv.Itoa(credentialTypeID))
	query.Set("organization", strconv.Itoa(organizationID))
	query.Set("page_size", "2")
	resp, err := getJSON(cfg, "/api/v2/credentials/?"+query.Encode())
	if err != nil {
		return nil, err
	}
	var page awxPage
	if err := json.Unmarshal(resp.Body, &page); err != nil {
		return nil, fmt.Errorf("decode callback credential preflight: %w", err)
	}
	if page.Count == 0 && len(page.Results) == 0 && page.Next == "" {
		return nil, nil
	}
	if page.Count != 1 || len(page.Results) != 1 || page.Next != "" {
		return nil, fmt.Errorf("callback credential preflight returned an ambiguous existing set")
	}
	existing, err := decodeAndVerifyCallbackCredential(
		page.Results[0],
		0,
		credentialName,
		credentialTypeID,
		organizationID,
	)
	if err != nil {
		return nil, err
	}
	return &existing, nil
}

func callbackCredentialConflictResult(credential awxCallbackCredentialSummary) *sdk.Result {
	payload := map[string]any{
		"verb":               "awx.create_callback_credential",
		"ok":                 false,
		"error":              "existing ephemeral callback credential requires cleanup before reissue",
		"cleanup_status":     "cleanup_required",
		"credential_id":      credential.ID,
		"credential_type_id": credential.CredentialType,
		"organization_id":    credential.Organization,
		"credential_name":    credential.Name,
	}
	out, _ := json.Marshal(payload)
	return sdk.Critical("awx.create_callback_credential: existing credential requires cleanup").
		WithDetails(string(out)).
		WithLabel("verb", "awx.create_callback_credential")
}

// runDeleteCallbackCredential verifies the exact reviewed credential identity
// before deleting it. A 404 during verification is an idempotent success; a
// credential with a mismatched name, type, or organization is never deleted.
func runDeleteCallbackCredential(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedDeleteCallbackCredentialArg); err != nil {
		return errorResult("awx.delete_callback_credential", err)
	}

	credentialID, ok := positiveArgID(cfg.Args, "credential_id")
	if !ok {
		return errorResult("awx.delete_callback_credential", fmt.Errorf("args.credential_id is required"))
	}
	credentialTypeID, ok := positiveArgID(cfg.Args, "credential_type_id")
	if !ok {
		return errorResult("awx.delete_callback_credential", fmt.Errorf("args.credential_type_id is required"))
	}
	organizationID, ok := positiveArgID(cfg.Args, "organization_id")
	if !ok {
		return errorResult("awx.delete_callback_credential", fmt.Errorf("args.organization_id is required"))
	}
	credentialName, ok := boundedCallbackCredentialName(cfg.Args)
	if !ok {
		return errorResult("awx.delete_callback_credential", fmt.Errorf("args.credential_name is invalid"))
	}

	path := fmt.Sprintf("/api/v2/credentials/%d/", credentialID)
	resp, absent, err := getJSONAllowNotFound(cfg, path)
	if err != nil {
		return errorResult("awx.delete_callback_credential", err)
	}
	if absent {
		return callbackCredentialDeleteResult(credentialID, credentialTypeID, "already_absent")
	}

	if _, err := decodeAndVerifyCallbackCredential(
		resp.Body,
		credentialID,
		credentialName,
		credentialTypeID,
		organizationID,
	); err != nil {
		return errorResult("awx.delete_callback_credential", err)
	}

	deleteResp, err := deleteJSON(cfg, path)
	if err != nil {
		return errorResult("awx.delete_callback_credential", err)
	}
	if deleteResp.Status == http.StatusNotFound {
		return callbackCredentialDeleteResult(credentialID, credentialTypeID, "already_absent")
	}
	return callbackCredentialDeleteResult(credentialID, credentialTypeID, "deleted")
}

func callbackCredentialDeleteResult(credentialID, credentialTypeID int, cleanupStatus string) *sdk.Result {
	payload := map[string]any{
		"verb":               "awx.delete_callback_credential",
		"ok":                 true,
		"credential_id":      credentialID,
		"credential_type_id": credentialTypeID,
		"cleanup_status":     cleanupStatus,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("callback credential %d cleanup: %s", credentialID, cleanupStatus)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.delete_callback_credential")
}

func validateExactArgs(args map[string]any, allowed func(string) bool) error {
	for key := range args {
		// TinyGo map[string]struct{} membership against JSON-unmarshaled keys has
		// been observed to fail closed even for compile-time-allowlisted fields.
		// Keep the allowlist as an explicit predicate (switch) instead.
		if !allowed(key) {
			return fmt.Errorf("args contain an unreviewed field %q", key)
		}
	}
	return nil
}

func positiveArgID(args map[string]any, key string) (int, bool) {
	value, ok := argInt(args, key)
	return value, ok && value > 0 && value <= math.MaxInt32
}

func boundedCallbackCredentialName(args map[string]any) (string, bool) {
	name, ok := argString(args, "credential_name")
	if !ok || len(name) == 0 || len(name) > maxCallbackCredentialNameBytes || strings.TrimSpace(name) != name {
		return "", false
	}
	if !strings.HasPrefix(name, "sr-callback-") {
		return "", false
	}
	for _, char := range name {
		if (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' {
			continue
		}
		return "", false
	}
	return name, true
}

func decodeAndVerifyCallbackCredential(
	body []byte,
	expectedID int,
	expectedName string,
	expectedCredentialTypeID int,
	expectedOrganizationID int,
) (awxCallbackCredentialSummary, error) {
	var credential awxCallbackCredentialSummary
	if err := json.Unmarshal(body, &credential); err != nil {
		return credential, fmt.Errorf("decode callback credential response: %w", err)
	}
	if credential.ID <= 0 || (expectedID > 0 && credential.ID != expectedID) {
		return credential, fmt.Errorf("AWX returned a mismatched callback credential ID")
	}
	if credential.Name != expectedName || credential.CredentialType != expectedCredentialTypeID ||
		credential.Organization != expectedOrganizationID {
		return credential, fmt.Errorf("AWX returned a mismatched callback credential binding")
	}
	return credential, nil
}

func notImplemented(verb string) *sdk.Result {
	return sdk.Critical(fmt.Sprintf("verb %q not yet implemented in this plugin build", verb))
}

// runLaunchJob handles `awx.launch_job` verb.
//
// Required args: template_id (positive int).
// Optional args are an explicit, typed allowlist of AWX 24.6.1
// JobLaunchSerializer fields:
//
//   - extra_vars (map), host_limit (string), inventory_id (positive int)
//   - credential_ids, labels, instance_group_ids (positive int arrays)
//   - execution_environment_id (positive int)
//   - job_type ("run" or "check"), diff_mode (bool), verbosity (0..5)
//   - forks, job_slice_count, timeout (bounded positive ints)
//   - job_tags, skip_tags (bounded strings)
//
// The API also accepts credential_passwords and scm_branch. They are
// deliberately not supported: ServiceRadar must not transport launch-time
// credential secrets or moving SCM references. Reserved dispatch values in
// extra_vars are non-secret, server-owned correlation markers; this plugin
// forwards them but never logs request bodies or credentials.
//
// AWX accepts a `limit:` parameter that scopes the run to a comma-joined list
// of host names — this is what the Device Actions modal sends when running
// against a specific selection of devices.
func runLaunchJob(cfg Config) *sdk.Result {
	templateID, ok := argInt(cfg.Args, "template_id")
	if !ok || templateID <= 0 {
		return errorResult("awx.launch_job", fmt.Errorf("args.template_id is required"))
	}

	reqBody, err := buildLaunchBody(cfg.Args)
	if err != nil {
		return errorResult("awx.launch_job", err)
	}

	resp, err := postJSON(cfg, fmt.Sprintf("/api/v2/job_templates/%d/launch/", templateID), reqBody)
	if err != nil {
		return errorResult("awx.launch_job", err)
	}

	job, err := sanitizeJobForReconciliation(resp.Body)
	if err != nil {
		return errorResult("awx.launch_job", fmt.Errorf("decode launch response: %w", err))
	}

	payload := map[string]any{
		"verb":        "awx.launch_job",
		"ok":          true,
		"template_id": templateID,
		"job":         job,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("launched job template %d", templateID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.launch_job")
}

var reconciliationJobFields = [...]string{
	"id",
	"job",
	"status",
	"created",
	"modified",
	"started",
	"finished",
	"canceled_on",
	"launch_type",
	"job_template",
	"inventory",
	"project",
	"scm_revision",
	"execution_environment",
	"job_type",
	"diff_mode",
	"verbosity",
	"forks",
	"job_slice_count",
	"job_slice_number",
	"timeout",
	"limit",
	"job_tags",
	"skip_tags",
	"instance_group",
	"failed",
}

// sanitizeJobForReconciliation keeps only fields required for lifecycle and
// accepted-job equality. In particular, AWX job detail can contain job_env,
// job_args, artifacts, result_traceback, password prompt names, and arbitrary
// extra_vars. None of those are returned through the plugin. Only the two
// non-secret, server-owned dispatch markers are extracted from extra_vars.
func sanitizeJobForReconciliation(raw []byte) (map[string]any, error) {
	var source map[string]any
	if err := json.Unmarshal(raw, &source); err != nil {
		return nil, err
	}
	job := make(map[string]any, len(reconciliationJobFields)+4)
	for _, field := range reconciliationJobFields {
		if value, present := source[field]; present {
			job[field] = value
		}
	}

	markers, err := dispatchMarkersFromJob(source["extra_vars"])
	if err != nil {
		return nil, err
	}
	if len(markers) > 0 {
		job["dispatch_markers"] = markers
	}

	if launchedBy, ok := source["launched_by"].(map[string]any); ok {
		identity := make(map[string]any, 2)
		for _, key := range []string{"id", "type"} {
			if value, present := launchedBy[key]; present {
				identity[key] = value
			}
		}
		if len(identity) > 0 {
			job["launched_by"] = identity
		}
	}

	if summaries, ok := source["summary_fields"].(map[string]any); ok {
		job["credentials"] = sanitizedCredentialSummaries(summaries["credentials"])
		labelIDs, labelCount := sanitizedLabelSummary(summaries["labels"])
		job["labels"] = labelIDs
		job["label_count"] = labelCount
	}

	return job, nil
}

func dispatchMarkersFromJob(raw any) (map[string]string, error) {
	if raw == nil || raw == "" {
		return nil, nil
	}
	var extraVars map[string]any
	switch value := raw.(type) {
	case string:
		if err := json.Unmarshal([]byte(value), &extraVars); err != nil {
			return nil, fmt.Errorf("decode AWX job extra_vars markers: %w", err)
		}
	case map[string]any:
		extraVars = value
	default:
		return nil, fmt.Errorf("AWX job extra_vars has unexpected type")
	}
	markers := make(map[string]string, len(reservedDispatchVars))
	for _, key := range reservedDispatchVars {
		if rawMarker, present := extraVars[key]; present {
			marker, ok := rawMarker.(string)
			if !ok || strings.TrimSpace(marker) == "" || len(marker) > maxLaunchMarkerBytes {
				return nil, fmt.Errorf("AWX job marker %s is invalid", key)
			}
			markers[key] = marker
		}
	}
	return markers, nil
}

func sanitizedCredentialSummaries(raw any) []map[string]any {
	values, ok := raw.([]any)
	if !ok {
		return []map[string]any{}
	}
	credentials := make([]map[string]any, 0, len(values))
	for _, value := range values {
		credential, ok := value.(map[string]any)
		if !ok {
			continue
		}
		safe := make(map[string]any, 2)
		for _, key := range []string{"id", "kind"} {
			if field, present := credential[key]; present {
				safe[key] = field
			}
		}
		if len(safe) > 0 {
			credentials = append(credentials, safe)
		}
	}
	return credentials
}

func sanitizedLabelSummary(raw any) ([]any, int) {
	labels, ok := raw.(map[string]any)
	if !ok {
		return []any{}, 0
	}
	count, countOK := argInt(labels, "count")
	values, ok := labels["results"].([]any)
	if !ok {
		return []any{}, 0
	}
	ids := make([]any, 0, len(values))
	for _, value := range values {
		if label, ok := value.(map[string]any); ok {
			if id, present := label["id"]; present {
				ids = append(ids, id)
			}
		}
	}
	if !countOK || count < len(ids) {
		count = len(ids)
	}
	return ids, count
}

const (
	maxLaunchLimitBytes    = 16 * 1024
	maxLaunchTagBytes      = 4 * 1024
	maxLaunchMarkerBytes   = 512
	maxLaunchIDCount       = 128
	maxLaunchForks         = 10_000
	maxLaunchJobSlices     = 10_000
	maxLaunchTimeoutSecond = 7 * 24 * 60 * 60
)

var reservedDispatchVars = [...]string{
	"serviceradar_dispatch_id",
	"serviceradar_snapshot_digest",
}

func buildLaunchBody(args map[string]any) (map[string]any, error) {
	for key := range args {
		if !allowedLaunchArg(key) {
			return nil, fmt.Errorf("launch arguments contain an unreviewed field %q", key)
		}
	}
	body := make(map[string]any)

	if raw, present := args["extra_vars"]; present {
		extraVars, ok := raw.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("args.extra_vars must be an object")
		}
		if err := validateDispatchMarkers(extraVars); err != nil {
			return nil, err
		}
		if len(extraVars) > 0 {
			body["extra_vars"] = extraVars
		}
	}

	if raw, present := args["host_limit"]; present {
		limit, ok := raw.(string)
		if !ok {
			return nil, fmt.Errorf("args.host_limit must be a string")
		}
		if strings.TrimSpace(limit) == "" {
			return nil, fmt.Errorf("args.host_limit must not be empty when provided")
		}
		if len(limit) > maxLaunchLimitBytes {
			return nil, fmt.Errorf("args.host_limit exceeds %d bytes", maxLaunchLimitBytes)
		}
		body["limit"] = limit
	}

	if err := putPositiveInt(args, body, "inventory_id", "inventory", math.MaxInt32); err != nil {
		return nil, err
	}
	if err := putPositiveInt(args, body, "execution_environment_id", "execution_environment", math.MaxInt32); err != nil {
		return nil, err
	}
	if err := putPositiveIntSlice(args, body, "credential_ids", "credentials"); err != nil {
		return nil, err
	}
	if err := putPositiveIntSlice(args, body, "labels", "labels"); err != nil {
		return nil, err
	}
	if err := putPositiveIntSlice(args, body, "instance_group_ids", "instance_groups"); err != nil {
		return nil, err
	}

	if raw, present := args["job_type"]; present {
		jobType, ok := raw.(string)
		if !ok || (jobType != "run" && jobType != "check") {
			return nil, fmt.Errorf("args.job_type must be %q or %q", "run", "check")
		}
		body["job_type"] = jobType
	}
	if raw, present := args["diff_mode"]; present {
		diffMode, ok := raw.(bool)
		if !ok {
			return nil, fmt.Errorf("args.diff_mode must be a boolean")
		}
		body["diff_mode"] = diffMode
	}
	if err := putBoundedInt(args, body, "verbosity", "verbosity", 0, 5); err != nil {
		return nil, err
	}
	if err := putBoundedInt(args, body, "forks", "forks", 1, maxLaunchForks); err != nil {
		return nil, err
	}
	if err := putBoundedInt(args, body, "job_slice_count", "job_slice_count", 1, maxLaunchJobSlices); err != nil {
		return nil, err
	}
	if err := putBoundedInt(args, body, "timeout", "timeout", 1, maxLaunchTimeoutSecond); err != nil {
		return nil, err
	}
	if err := putBoundedString(args, body, "job_tags", "job_tags", maxLaunchTagBytes); err != nil {
		return nil, err
	}
	if err := putBoundedString(args, body, "skip_tags", "skip_tags", maxLaunchTagBytes); err != nil {
		return nil, err
	}

	return body, nil
}

func validateDispatchMarkers(extraVars map[string]any) error {
	for _, key := range reservedDispatchVars {
		raw, present := extraVars[key]
		if !present {
			continue
		}
		marker, ok := raw.(string)
		if !ok || strings.TrimSpace(marker) == "" {
			return fmt.Errorf("args.extra_vars.%s must be a non-empty string", key)
		}
		if len(marker) > maxLaunchMarkerBytes {
			return fmt.Errorf("args.extra_vars.%s exceeds %d bytes", key, maxLaunchMarkerBytes)
		}
	}
	return nil
}

func putPositiveInt(args, body map[string]any, argKey, awxKey string, max int) error {
	if _, present := args[argKey]; !present {
		return nil
	}
	return putBoundedInt(args, body, argKey, awxKey, 1, max)
}

func putBoundedInt(args, body map[string]any, argKey, awxKey string, min, max int) error {
	if _, present := args[argKey]; !present {
		return nil
	}
	value, ok := argInt(args, argKey)
	if !ok || value < min || value > max {
		return fmt.Errorf("args.%s must be an integer between %d and %d", argKey, min, max)
	}
	body[awxKey] = value
	return nil
}

func putPositiveIntSlice(args, body map[string]any, argKey, awxKey string) error {
	if _, present := args[argKey]; !present {
		return nil
	}
	values, ok := argIntSlice(args, argKey)
	if !ok || len(values) == 0 || len(values) > maxLaunchIDCount {
		return fmt.Errorf("args.%s must contain 1..%d positive integer IDs", argKey, maxLaunchIDCount)
	}
	seen := make(map[int]struct{}, len(values))
	for _, value := range values {
		if value <= 0 {
			return fmt.Errorf("args.%s must contain 1..%d positive integer IDs", argKey, maxLaunchIDCount)
		}
		if _, duplicate := seen[value]; duplicate {
			return fmt.Errorf("args.%s must not contain duplicate IDs", argKey)
		}
		seen[value] = struct{}{}
	}
	body[awxKey] = values
	return nil
}

func putBoundedString(args, body map[string]any, argKey, awxKey string, maxBytes int) error {
	raw, present := args[argKey]
	if !present {
		return nil
	}
	value, ok := raw.(string)
	if !ok {
		return fmt.Errorf("args.%s must be a string", argKey)
	}
	if value == "" {
		return nil
	}
	if len(value) > maxBytes {
		return fmt.Errorf("args.%s exceeds %d bytes", argKey, maxBytes)
	}
	body[awxKey] = value
	return nil
}

// runFetchJob handles `awx.fetch_job` verb. Required arg: job_id.
//
// RunPulseWorker uses this to detect terminal-status transitions when no
// new task events have fired in a tick (the watermark hasn't moved but the
// job may have finished).
func runFetchJob(cfg Config) *sdk.Result {
	jobID, ok := argInt(cfg.Args, "job_id")
	if !ok || jobID <= 0 {
		return errorResult("awx.fetch_job", fmt.Errorf("args.job_id is required"))
	}
	resp, err := getJSON(cfg, fmt.Sprintf("/api/v2/jobs/%d/", jobID))
	if err != nil {
		return errorResult("awx.fetch_job", err)
	}
	job, err := sanitizeJobForReconciliation(resp.Body)
	if err != nil {
		return errorResult("awx.fetch_job", fmt.Errorf("decode job: %w", err))
	}
	payload := map[string]any{
		"verb":   "awx.fetch_job",
		"ok":     true,
		"job_id": jobID,
		"job":    job,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("fetched job %d", jobID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.fetch_job")
}

// runCurrentUser handles `awx.current_user`: GET /api/v2/me/.
//
// The returned numeric AWX user ID is snapshotted by the control plane and is
// later required by awx.list_recent_jobs. Usernames are display text, never a
// dispatch-reconciliation identity.
func runCurrentUser(cfg Config) *sdk.Result {
	resp, err := getJSON(cfg, "/api/v2/me/?page_size=2")
	if err != nil {
		return errorResult("awx.current_user", err)
	}
	var page awxPage
	if err := json.Unmarshal(resp.Body, &page); err != nil {
		return errorResult("awx.current_user", fmt.Errorf("decode current user: %w", err))
	}
	if page.Count != 1 || len(page.Results) != 1 {
		return errorResult("awx.current_user", fmt.Errorf("AWX current-user response must contain exactly one user"))
	}
	var user struct {
		ID       int    `json:"id"`
		Username string `json:"username"`
	}
	if err := json.Unmarshal(page.Results[0], &user); err != nil || user.ID <= 0 ||
		user.ID > math.MaxInt32 || !safeStaticText(user.Username, 150) {
		return errorResult("awx.current_user", fmt.Errorf("AWX returned an invalid current-user identity"))
	}
	payload := map[string]any{
		"verb":     "awx.current_user",
		"ok":       true,
		"user_id":  user.ID,
		"username": user.Username,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok("fetched AWX integration identity").
		WithDetails(string(out)).
		WithLabel("verb", "awx.current_user")
}

const (
	maxRecentJobsPageSize  = 100
	maxRecentJobCandidates = 5_000
)

// runListRecentJobs handles `awx.list_recent_jobs`.
//
// Required args: template_id, inventory_id, created_by_id (positive ints) and
// created_after (RFC3339 timestamp), page_size (1..100), and max_candidates
// (1..5000). AwxClient selects the durable 5000-candidate ceiling.
// The plugin intentionally does not filter by dispatch marker: AWX 24.6.1
// marks extra_vars non-searchable. It walks the complete bounded, newest-first
// result set and fails on count drift, invalid pagination, duplicate IDs, or a
// controller-reported count above the durable ceiling. The trusted control
// plane still compares exact retained markers and accepted-job fields.
func runListRecentJobs(cfg Config) *sdk.Result {
	if err := validateExactArgs(cfg.Args, allowedListRecentJobArg); err != nil {
		return errorResult("awx.list_recent_jobs", err)
	}

	templateID, templateOK := positiveArgID(cfg.Args, "template_id")
	inventoryID, inventoryOK := positiveArgID(cfg.Args, "inventory_id")
	createdByID, createdByOK := positiveArgID(cfg.Args, "created_by_id")
	createdAfter, createdAfterOK := argString(cfg.Args, "created_after")
	if !templateOK {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.template_id is required"))
	}
	if !inventoryOK {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.inventory_id is required"))
	}
	if !createdByOK {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.created_by_id is required"))
	}
	createdAt, err := time.Parse(time.RFC3339, createdAfter)
	if !createdAfterOK || err != nil {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.created_after must be RFC3339"))
	}
	pageSize, ok := argInt(cfg.Args, "page_size")
	if !ok || pageSize <= 0 || pageSize > maxRecentJobsPageSize {
		return errorResult(
			"awx.list_recent_jobs",
			fmt.Errorf("args.page_size must be an integer between 1 and %d", maxRecentJobsPageSize),
		)
	}
	maxCandidates, ok := argInt(cfg.Args, "max_candidates")
	if !ok || maxCandidates <= 0 || maxCandidates > maxRecentJobCandidates {
		return errorResult(
			"awx.list_recent_jobs",
			fmt.Errorf("args.max_candidates must be an integer between 1 and %d", maxRecentJobCandidates),
		)
	}

	query := url.Values{}
	query.Set("job_template", strconv.Itoa(templateID))
	query.Set("inventory", strconv.Itoa(inventoryID))
	query.Set("created_by", strconv.Itoa(createdByID))
	query.Set("created__gte", createdAt.UTC().Format(time.RFC3339Nano))
	query.Set("order_by", "-created")
	query.Set("page_size", strconv.Itoa(pageSize))
	path := "/api/v2/jobs/?" + query.Encode()

	jobs, total, err := listRecentJobsBounded(
		cfg,
		path,
		pageSize,
		maxCandidates,
		templateID,
		inventoryID,
		createdByID,
		createdAt,
	)
	if err != nil {
		return errorResult("awx.list_recent_jobs", err)
	}
	payload := map[string]any{
		"verb":           "awx.list_recent_jobs",
		"ok":             true,
		"template_id":    templateID,
		"inventory_id":   inventoryID,
		"created_by_id":  createdByID,
		"created_after":  createdAt.UTC().Format(time.RFC3339Nano),
		"page_size":      pageSize,
		"max_candidates": maxCandidates,
		"count":          total,
		"complete":       true,
		"jobs":           jobs,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("listed %d recent jobs", total)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.list_recent_jobs")
}

func listRecentJobsBounded(
	cfg Config,
	path string,
	pageSize int,
	maxCandidates int,
	templateID int,
	inventoryID int,
	createdByID int,
	createdAfter time.Time,
) ([]map[string]any, int, error) {
	jobs := make([]map[string]any, 0)
	seenIDs := make(map[int]struct{})
	expectedCount := -1
	next := path
	pagesWalked := 0

	for next != "" {
		pagesWalked++
		if pagesWalked > maxCandidates {
			return nil, 0, fmt.Errorf("AWX recent-job pagination exceeded its request bound")
		}

		resp, err := getJSON(cfg, next)
		if err != nil {
			return nil, 0, err
		}
		var page awxPage
		if err := json.Unmarshal(resp.Body, &page); err != nil {
			return nil, 0, fmt.Errorf("decode recent jobs: %w", err)
		}
		if page.Count < 0 || page.Count > maxCandidates {
			return nil, 0, fmt.Errorf("AWX recent-job count exceeds the durable candidate bound")
		}
		if expectedCount == -1 {
			expectedCount = page.Count
		} else if page.Count != expectedCount {
			return nil, 0, fmt.Errorf("AWX recent-job count changed during pagination")
		}
		if len(page.Results) > pageSize || len(jobs)+len(page.Results) > expectedCount {
			return nil, 0, fmt.Errorf("AWX recent-job pagination is inconsistent")
		}
		if len(page.Results) == 0 && page.Next != "" {
			return nil, 0, fmt.Errorf("AWX recent-job pagination returned an empty non-terminal page")
		}

		for _, rawJob := range page.Results {
			job, err := sanitizeJobForReconciliation(rawJob)
			if err != nil {
				return nil, 0, fmt.Errorf("decode recent job: %w", err)
			}
			if err := validateRecentJobScope(
				job,
				templateID,
				inventoryID,
				createdByID,
				createdAfter,
			); err != nil {
				return nil, 0, err
			}
			jobID, _ := argInt(job, "id")
			if _, duplicate := seenIDs[jobID]; duplicate {
				return nil, 0, fmt.Errorf("AWX recent-job pagination returned a duplicate job ID")
			}
			seenIDs[jobID] = struct{}{}
			jobs = append(jobs, job)
		}

		rawNext := page.Next
		next = relativizeAWXPath(rawNext)
		if rawNext != "" && next == "" {
			return nil, 0, fmt.Errorf("AWX recent-job pagination returned an invalid next link")
		}
	}

	if expectedCount < 0 || len(jobs) != expectedCount {
		return nil, 0, fmt.Errorf("AWX recent-job pagination returned an incomplete candidate set")
	}
	return jobs, expectedCount, nil
}

func validateRecentJobScope(job map[string]any, templateID, inventoryID, createdByID int, createdAfter time.Time) error {
	jobID, jobOK := argInt(job, "id")
	gotTemplateID, templateOK := argInt(job, "job_template")
	gotInventoryID, inventoryOK := argInt(job, "inventory")
	launchedBy, launchedByOK := job["launched_by"].(map[string]any)
	gotCreatedByID, createdByOK := argInt(launchedBy, "id")
	created, createdOK := job["created"].(string)
	createdAt, createdErr := time.Parse(time.RFC3339, created)
	if !jobOK || jobID <= 0 || !templateOK || gotTemplateID != templateID ||
		!inventoryOK || gotInventoryID != inventoryID ||
		!launchedByOK || !createdByOK || gotCreatedByID != createdByID ||
		!createdOK || createdErr != nil || createdAt.Before(createdAfter) {
		return fmt.Errorf("AWX returned a recent job outside the requested exact scope")
	}
	return nil
}

const (
	defaultMaxJobHostSummaries = 1_000
	maxJobHostSummaries        = 10_000
)

type awxJobHostSummary struct {
	ID                int    `json:"id"`
	JobID             int    `json:"job"`
	HostID            *int   `json:"host"`
	ConstructedHostID *int   `json:"constructed_host"`
	HostName          string `json:"host_name"`
	Changed           int    `json:"changed"`
	Dark              int    `json:"dark"`
	Failures          int    `json:"failures"`
	OK                int    `json:"ok"`
	Processed         int    `json:"processed"`
	Skipped           int    `json:"skipped"`
	Failed            bool   `json:"failed"`
	Ignored           int    `json:"ignored"`
	Rescued           int    `json:"rescued"`
}

type jobHostSummaryResult struct {
	SummaryID         int    `json:"summary_id"`
	JobID             int    `json:"job_id"`
	HostID            *int   `json:"host_id,omitempty"`
	ConstructedHostID *int   `json:"constructed_host_id,omitempty"`
	HostName          string `json:"host_name"`
	Changed           int    `json:"changed"`
	Dark              int    `json:"dark"`
	Failures          int    `json:"failures"`
	OK                int    `json:"ok"`
	Processed         int    `json:"processed"`
	Skipped           int    `json:"skipped"`
	Failed            bool   `json:"failed"`
	Ignored           int    `json:"ignored"`
	Rescued           int    `json:"rescued"`
}

// runFetchJobHostSummaries handles `awx.fetch_job_host_summaries`.
//
// It fully paginates /jobs/{id}/job_host_summaries/ only while the controller
// reported count stays within max_hosts (default 1000, hard cap 10000). The
// normalized output preserves AWX host IDs and constructed-host IDs separately;
// a missing host ID remains missing and is never guessed from host_name.
func runFetchJobHostSummaries(cfg Config) *sdk.Result {
	jobID, ok := argInt(cfg.Args, "job_id")
	if !ok || jobID <= 0 {
		return errorResult("awx.fetch_job_host_summaries", fmt.Errorf("args.job_id is required"))
	}
	maxHosts := defaultMaxJobHostSummaries
	if _, present := cfg.Args["max_hosts"]; present {
		maxHosts, ok = argInt(cfg.Args, "max_hosts")
		if !ok || maxHosts <= 0 || maxHosts > maxJobHostSummaries {
			return errorResult(
				"awx.fetch_job_host_summaries",
				fmt.Errorf("args.max_hosts must be an integer between 1 and %d", maxJobHostSummaries),
			)
		}
	}

	path := fmt.Sprintf("/api/v2/jobs/%d/job_host_summaries/?page_size=200&order_by=id", jobID)
	rawSummaries, total, err := listAWXPathBounded(cfg, path, maxHosts)
	if err != nil {
		return errorResult("awx.fetch_job_host_summaries", err)
	}
	summaries := make([]jobHostSummaryResult, 0, len(rawSummaries))
	for _, raw := range rawSummaries {
		var summary awxJobHostSummary
		if err := json.Unmarshal(raw, &summary); err != nil {
			return errorResult("awx.fetch_job_host_summaries", fmt.Errorf("decode job host summary: %w", err))
		}
		if summary.ID <= 0 || summary.JobID != jobID {
			return errorResult("awx.fetch_job_host_summaries", fmt.Errorf("AWX returned a host summary outside job %d", jobID))
		}
		if summary.HostID != nil && *summary.HostID <= 0 {
			return errorResult("awx.fetch_job_host_summaries", fmt.Errorf("AWX returned an invalid host ID for job %d", jobID))
		}
		if summary.ConstructedHostID != nil && *summary.ConstructedHostID <= 0 {
			return errorResult("awx.fetch_job_host_summaries", fmt.Errorf("AWX returned an invalid constructed host ID for job %d", jobID))
		}
		summaries = append(summaries, jobHostSummaryResult{
			SummaryID:         summary.ID,
			JobID:             summary.JobID,
			HostID:            summary.HostID,
			ConstructedHostID: summary.ConstructedHostID,
			HostName:          summary.HostName,
			Changed:           summary.Changed,
			Dark:              summary.Dark,
			Failures:          summary.Failures,
			OK:                summary.OK,
			Processed:         summary.Processed,
			Skipped:           summary.Skipped,
			Failed:            summary.Failed,
			Ignored:           summary.Ignored,
			Rescued:           summary.Rescued,
		})
	}

	payload := map[string]any{
		"verb":      "awx.fetch_job_host_summaries",
		"ok":        true,
		"job_id":    jobID,
		"count":     total,
		"summaries": summaries,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("fetched %d host summaries for job %d", total, jobID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.fetch_job_host_summaries")
}

// runCancelJob handles `awx.cancel_job` verb. Required arg: job_id.
//
// AWX's cancel endpoint accepts an empty POST and returns 202 when the job
// is cancelable. We don't pre-check `can_cancel` — the eventual GET
// /api/v2/jobs/{id}/ via fetch_job will surface the canceled state.
func runCancelJob(cfg Config) *sdk.Result {
	jobID, ok := argInt(cfg.Args, "job_id")
	if !ok {
		return errorResult("awx.cancel_job", fmt.Errorf("args.job_id is required"))
	}
	resp, err := postJSON(cfg, fmt.Sprintf("/api/v2/jobs/%d/cancel/", jobID), nil)
	if err != nil {
		return errorResult("awx.cancel_job", err)
	}
	payload := map[string]any{
		"verb":   "awx.cancel_job",
		"ok":     true,
		"job_id": jobID,
		"status": resp.Status,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("canceled job %d", jobID)).
		WithDetails(string(out)).
		WithLabel("verb", "awx.cancel_job")
}

// jobEventsResult is one entry in the fetch_events_for_jobs response.
type jobEventsResult struct {
	JobID      int               `json:"job_id"`
	OK         bool              `json:"ok"`
	Error      string            `json:"error,omitempty"`
	Events     []json.RawMessage `json:"events"`
	MaxCounter int               `json:"max_counter"`
	Count      int               `json:"count"`
}

type jobEventPair struct {
	JobID   int
	SinceID int
}

type projectedAWXEvent struct {
	Event     string         `json:"event"`
	Counter   int            `json:"counter"`
	Created   string         `json:"created,omitempty"`
	Changed   *bool          `json:"changed,omitempty"`
	Failed    *bool          `json:"failed,omitempty"`
	EventData map[string]any `json:"event_data"`
}

const (
	maxJobsPerEventFetch  = 10
	maxEventsPerJobFetch  = 10
	maxAWXEventNameBytes  = 256
	maxAWXEventPathBytes  = 1024
	maxAWXEventStatsHosts = 10_000
	awxEventFetchFailure  = "awx_event_fetch_failed"
)

var handledAWXEventNames = [...]string{
	"playbook_on_play_start",
	"playbook_on_task_start",
	"playbook_on_handler_task_start",
	"runner_on_ok",
	"runner_on_failed",
	"runner_on_skipped",
	"runner_on_unreachable",
	"runner_item_on_ok",
	"runner_item_on_failed",
	"runner_item_on_skipped",
	"playbook_on_stats",
}

// runFetchEventsForJobs handles `awx.fetch_events_for_jobs` verb — the bulk
// pulse verb RunPulseWorker drives. Args: pairs ([]{job_id, since_id}).
//
// For each pair we GET one ordered ten-event window from
// /api/v2/jobs/{id}/job_events/?counter__gt={since_id}. We deliberately do not
// follow AWX's next page: advancing the bounded watermark lets the next pulse
// consume the next window without ever materializing an unbounded event stream
// in one agent result. Every returned event is projected into the exact subset
// EventIngestor consumes before it is placed in the plugin result.
func runFetchEventsForJobs(cfg Config) *sdk.Result {
	pairs, err := validatedJobEventPairs(cfg.Args)
	if err != nil {
		return errorResult("awx.fetch_events_for_jobs", err)
	}

	jobs := make([]jobEventsResult, 0, len(pairs))
	successful := 0
	for _, pair := range pairs {
		path := fmt.Sprintf(
			"/api/v2/jobs/%d/job_events/?counter__gt=%d&page_size=%d&order_by=counter",
			pair.JobID, pair.SinceID, maxEventsPerJobFetch,
		)
		events, maxCounter, err := fetchProjectedJobEventWindow(cfg, path, pair.SinceID)
		if err != nil {
			jobs = append(jobs, jobEventsResult{
				JobID:  pair.JobID,
				OK:     false,
				Error:  awxEventFetchFailure,
				Events: []json.RawMessage{},
			})
			continue
		}

		jobs = append(jobs, jobEventsResult{
			JobID:      pair.JobID,
			OK:         true,
			Events:     events,
			MaxCounter: maxCounter,
			Count:      len(events),
		})
		successful++
	}

	payload := map[string]any{
		"verb":             "awx.fetch_events_for_jobs",
		"ok":               true,
		"contract_version": 2,
		"jobs":             jobs,
	}
	out, _ := json.Marshal(payload)

	return sdk.Ok(fmt.Sprintf("fetched events for %d/%d jobs", successful, len(jobs))).
		WithDetails(string(out)).
		WithLabel("verb", "awx.fetch_events_for_jobs")
}

func validatedJobEventPairs(args map[string]any) ([]jobEventPair, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("args must contain only pairs")
	}
	rawPairs, present := args["pairs"]
	if !present {
		return nil, fmt.Errorf("args.pairs is required")
	}

	var values []any
	switch pairs := rawPairs.(type) {
	case []any:
		values = pairs
	case []map[string]any:
		values = make([]any, len(pairs))
		for i := range pairs {
			values[i] = pairs[i]
		}
	default:
		return nil, fmt.Errorf("args.pairs must be an array")
	}
	if len(values) < 1 || len(values) > maxJobsPerEventFetch {
		return nil, fmt.Errorf("args.pairs must contain between 1 and %d entries", maxJobsPerEventFetch)
	}

	out := make([]jobEventPair, 0, len(values))
	seenJobs := make(map[int]struct{}, len(values))
	for _, rawPair := range values {
		pair, ok := rawPair.(map[string]any)
		if !ok || len(pair) != 2 {
			return nil, fmt.Errorf("each pair must contain exactly job_id and since_id")
		}
		if _, ok := pair["job_id"]; !ok {
			return nil, fmt.Errorf("each pair must contain exactly job_id and since_id")
		}
		if _, ok := pair["since_id"]; !ok {
			return nil, fmt.Errorf("each pair must contain exactly job_id and since_id")
		}
		jobID, jobOK := argInt(pair, "job_id")
		sinceID, sinceOK := argInt(pair, "since_id")
		if !jobOK || jobID <= 0 || jobID > math.MaxInt32 ||
			!sinceOK || sinceID < 0 || sinceID > math.MaxInt32 {
			return nil, fmt.Errorf("pair identifiers are invalid")
		}
		if _, duplicate := seenJobs[jobID]; duplicate {
			return nil, fmt.Errorf("args.pairs must contain unique job IDs")
		}
		seenJobs[jobID] = struct{}{}
		out = append(out, jobEventPair{JobID: jobID, SinceID: sinceID})
	}
	return out, nil
}

func fetchProjectedJobEventWindow(
	cfg Config,
	path string,
	sinceID int,
) ([]json.RawMessage, int, error) {
	resp, err := getJSON(cfg, path)
	if err != nil {
		return nil, sinceID, err
	}
	var page awxPage
	if err := json.Unmarshal(resp.Body, &page); err != nil {
		return nil, sinceID, fmt.Errorf("invalid AWX event page")
	}
	if page.Count < 0 || len(page.Results) > maxEventsPerJobFetch {
		return nil, sinceID, fmt.Errorf("invalid AWX event page")
	}

	projected := make([]json.RawMessage, 0, len(page.Results))
	maxCounter := sinceID
	for _, raw := range page.Results {
		counter, event, keep, err := projectAWXJobEvent(raw)
		if err != nil || counter <= maxCounter {
			return nil, sinceID, fmt.Errorf("invalid AWX event window")
		}
		maxCounter = counter
		if keep {
			projected = append(projected, event)
		}
	}
	return projected, maxCounter, nil
}

func projectAWXJobEvent(raw json.RawMessage) (int, json.RawMessage, bool, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return 0, nil, false, err
	}
	counter64, ok := rawInteger(root["counter"], 1, math.MaxInt32)
	if !ok {
		return 0, nil, false, fmt.Errorf("invalid event counter")
	}
	counter := int(counter64)

	eventName, ok := rawString(root["event"])
	if !ok {
		return counter, nil, false, nil
	}
	if !stringIn(eventName, handledAWXEventNames[:]...) {
		return counter, nil, false, nil
	}

	var rawEventData map[string]json.RawMessage
	if err := json.Unmarshal(root["event_data"], &rawEventData); err != nil {
		return 0, nil, false, fmt.Errorf("invalid handled AWX event data")
	}
	eventData, valid := projectAWXEventData(eventName, rawEventData)
	if !valid {
		return 0, nil, false, fmt.Errorf("invalid handled AWX event data")
	}

	projected := projectedAWXEvent{
		Event:     eventName,
		Counter:   counter,
		EventData: eventData,
	}
	if eventName != "playbook_on_stats" {
		if created, ok := rawString(root["created"]); ok && validRFC3339(created) {
			projected.Created = created
		}
	}
	if strings.HasPrefix(eventName, "runner_") {
		if changed, ok := rawBool(root["changed"]); ok {
			projected.Changed = &changed
		}
		if failed, ok := rawBool(root["failed"]); ok {
			projected.Failed = &failed
		}
	}

	out, err := json.Marshal(projected)
	if err != nil {
		return 0, nil, false, err
	}
	return counter, out, true, nil
}

func projectAWXEventData(eventName string, raw map[string]json.RawMessage) (map[string]any, bool) {
	if eventName == "playbook_on_stats" {
		return projectAWXStats(raw)
	}

	data := make(map[string]any)
	playUUID, hasPlayUUID := projectedUUID(raw["play_uuid"])
	if !hasPlayUUID {
		return nil, false
	}
	data["play_uuid"] = playUUID

	if eventName != "playbook_on_play_start" {
		taskUUID, hasTaskUUID := projectedUUID(raw["task_uuid"])
		if !hasTaskUUID {
			return nil, false
		}
		data["task_uuid"] = taskUUID
	}

	if eventName == "playbook_on_play_start" {
		projectBoundedText(data, "play", raw["play"], maxAWXEventNameBytes)
		projectBoundedText(data, "name", raw["name"], maxAWXEventNameBytes)
		return data, true
	}

	projectBoundedText(data, "play", raw["play"], maxAWXEventNameBytes)
	projectBoundedText(data, "task", raw["task"], maxAWXEventNameBytes)
	projectBoundedText(data, "name", raw["name"], maxAWXEventNameBytes)
	projectBoundedText(data, "task_action", raw["task_action"], maxAWXEventNameBytes)

	if strings.HasPrefix(eventName, "playbook_on_") {
		projectBoundedText(data, "task_path", raw["task_path"], maxAWXEventPathBytes)
		if line, ok := rawInteger(raw["task_line_number"], 1, math.MaxInt32); ok {
			data["task_line_number"] = line
		}
	}

	if strings.HasPrefix(eventName, "runner_") {
		host, ok := projectedHostToken(raw["host"])
		if !ok {
			return nil, false
		}
		data["host"] = host
		if ignoreErrors, ok := rawBool(raw["ignore_errors"]); ok {
			data["ignore_errors"] = ignoreErrors
		}
		if delegated, ok := projectedHostToken(raw["delegated"]); ok {
			data["delegated"] = delegated
		}
		if result := projectAWXResult(raw["res"]); result != nil {
			data["res"] = result
		}
	}

	return data, true
}

func projectAWXResult(raw json.RawMessage) map[string]any {
	var result map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &result) != nil {
		return nil
	}
	rc, ok := rawInteger(result["rc"], math.MinInt32, math.MaxInt32)
	if !ok {
		return nil
	}
	return map[string]any{"rc": rc}
}

func projectAWXStats(raw map[string]json.RawMessage) (map[string]any, bool) {
	data := make(map[string]any, 5)
	for _, field := range []string{"ok", "failures", "dark", "skipped", "changed"} {
		stats, ok := projectedNumericHostMap(raw[field])
		if !ok {
			return nil, false
		}
		data[field] = stats
	}
	return data, true
}

func projectedNumericHostMap(raw json.RawMessage) (map[string]int64, bool) {
	var values map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &values) != nil || len(values) > maxAWXEventStatsHosts {
		return nil, false
	}
	out := make(map[string]int64, len(values))
	for host, rawCount := range values {
		if !literalAWXHostToken(host) {
			return nil, false
		}
		count, ok := rawInteger(rawCount, 0, math.MaxInt32)
		if !ok {
			return nil, false
		}
		out[host] = count
	}
	return out, true
}

func projectBoundedText(out map[string]any, key string, raw json.RawMessage, maxBytes int) {
	if value, ok := rawString(raw); ok && safeStaticText(value, maxBytes) {
		out[key] = value
	}
}

func projectedUUID(raw json.RawMessage) (string, bool) {
	value, ok := rawString(raw)
	return value, ok && lowerUUID(value)
}

func projectedHostToken(raw json.RawMessage) (string, bool) {
	value, ok := rawString(raw)
	return value, ok && literalAWXHostToken(value)
}

func rawString(raw json.RawMessage) (string, bool) {
	if len(raw) == 0 {
		return "", false
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", false
	}
	return value, true
}

func rawBool(raw json.RawMessage) (bool, bool) {
	if len(raw) == 0 {
		return false, false
	}
	var value bool
	if err := json.Unmarshal(raw, &value); err != nil {
		return false, false
	}
	return value, true
}

func rawInteger(raw json.RawMessage, minValue, maxValue int64) (int64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	value, err := strconv.ParseInt(string(raw), 10, 64)
	return value, err == nil && value >= minValue && value <= maxValue
}

func validRFC3339(value string) bool {
	if len(value) == 0 || len(value) > len(time.RFC3339Nano)+10 {
		return false
	}
	_, err := time.Parse(time.RFC3339Nano, value)
	return err == nil
}

func lowerUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for i, char := range []byte(value) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

func literalAWXHostToken(value string) bool {
	if len(value) == 0 || len(value) > 255 || value == "all" || value == "ungrouped" {
		return false
	}
	for i, char := range []byte(value) {
		if (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || (i > 0 && (char == '.' || char == '_' || char == '-')) {
			continue
		}
		return false
	}
	return true
}

func safeStaticText(value string, maxBytes int) bool {
	return boundedStaticText(value, maxBytes, false)
}

func boundedStaticText(value string, maxBytes int, allowEmpty bool) bool {
	if (!allowEmpty && value == "") || len(value) > maxBytes || !utf8.ValidString(value) {
		return false
	}
	for _, char := range value {
		if unicode.IsControl(char) || unicode.Is(unicode.Cf, char) {
			return false
		}
	}
	return true
}

// argString extracts a string arg.
func argString(args map[string]any, key string) (string, bool) {
	v, ok := args[key]
	if !ok {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}

// argMap extracts a nested map arg (e.g. extra_vars).
func argMap(args map[string]any, key string) (map[string]any, bool) {
	v, ok := args[key]
	if !ok {
		return nil, false
	}
	m, ok := v.(map[string]any)
	return m, ok
}

// postJSON performs an authenticated POST. A nil body is encoded as no body
// (used by the cancel endpoint, which expects an empty POST).
func postJSON(cfg Config, path string, body any) (*sdk.HTTPResponse, error) {
	timeoutMS := cfg.TimeoutMS
	if timeoutMS <= 0 {
		timeoutMS = defaultTimeoutMS
	}

	var bodyBytes []byte
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("encode body: %w", err)
		}
		bodyBytes = b
	}

	req := sdk.HTTPRequest{
		Method: http.MethodPost,
		URL:    strings.TrimRight(cfg.BaseURL, "/") + path,
		Headers: map[string]string{
			"Authorization": "Bearer " + cfg.APIToken,
			"Accept":        "application/json",
			"Content-Type":  "application/json",
		},
		Body:               bodyBytes,
		TimeoutMS:          timeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}

	resp, err := awxHTTP.Do(req)
	if err != nil {
		return nil, errAWXRequestFailed
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return nil, errAWXRequestFailed
	}
	return resp, nil
}

// deleteJSON performs an authenticated DELETE. A 404 is returned to the caller
// as a valid idempotent-cleanup state; other non-2xx responses fail closed.
func deleteJSON(cfg Config, path string) (*sdk.HTTPResponse, error) {
	timeoutMS := cfg.TimeoutMS
	if timeoutMS <= 0 {
		timeoutMS = defaultTimeoutMS
	}

	req := sdk.HTTPRequest{
		Method: http.MethodDelete,
		URL:    strings.TrimRight(cfg.BaseURL, "/") + path,
		Headers: map[string]string{
			"Authorization": "Bearer " + cfg.APIToken,
			"Accept":        "application/json",
		},
		TimeoutMS:          timeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}
	resp, err := awxHTTP.Do(req)
	if err != nil {
		return nil, errAWXRequestFailed
	}
	if resp.Status == http.StatusNotFound {
		return resp, nil
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return nil, errAWXRequestFailed
	}
	return resp, nil
}

// runPing handles `awx.ping` verb: GET /api/v2/ping/.
//
// Result.Status reflects controller reachability for the plugin tile UI;
// Result.Details carries the structured payload AwxClient parses on the
// Elixir side.
func runPing(cfg Config) *sdk.Result {
	resp, err := getJSON(cfg, "/api/v2/ping/")
	if err != nil {
		return errorResult("awx.ping", err)
	}

	var ping map[string]json.RawMessage
	if err := json.Unmarshal(resp.Body, &ping); err != nil {
		return errorResult("awx.ping", fmt.Errorf("decode AWX ping response: %w", err))
	}
	version, versionOK := rawString(ping["version"])
	activeNode, activeNodeOK := rawString(ping["active_node"])
	if !versionOK || !safeStaticText(version, 64) ||
		!activeNodeOK || !safeStaticText(activeNode, 255) {
		return errorResult("awx.ping", fmt.Errorf("AWX returned an invalid ping response"))
	}

	payload := map[string]any{
		"verb":        "awx.ping",
		"ok":          true,
		"version":     version,
		"active_node": activeNode,
	}
	body, _ := json.Marshal(payload)

	summary := "AWX " + version + " reachable (active: " + activeNode + ")"

	result := sdk.Ok(summary).
		WithDetails(string(body)).
		WithLabel("verb", "awx.ping")
	result.WithLabel("awx_version", version)
	result.WithLabel("active_node", activeNode)
	return result
}

// awxPage is the envelope every paginated AWX list endpoint returns.
type awxPage struct {
	Count    int               `json:"count"`
	Next     string            `json:"next"`
	Previous string            `json:"previous"`
	Results  []json.RawMessage `json:"results"`
}

// Pagination is bounded and exact: callers either receive the whole result set
// inside their declared cap or a typed error. Partial inventory/group/host
// lists cannot safely prove target equality.
const (
	awxPageSize        = 200
	maxPaginationPages = 50
	maxPaginatedRows   = awxPageSize * maxPaginationPages
)

// listAWXPath walks /api/v2/<resource>/?... following the `next` link until
// it's null or we hit `maxPaginationPages`. Returns the aggregated raw
// results and the controller-reported total count.
func listAWXPath(cfg Config, path string) ([]json.RawMessage, int, error) {
	return listAWXPathBounded(cfg, path, maxPaginatedRows)
}

func listAWXPathBounded(cfg Config, path string, maxResults int) ([]json.RawMessage, int, error) {
	if maxResults <= 0 || maxResults > maxPaginatedRows {
		return nil, 0, fmt.Errorf("AWX pagination bound must be between 1 and %d", maxPaginatedRows)
	}
	var (
		all   []json.RawMessage
		total int
		next  = path
	)
	pagesWalked := 0
	for next != "" {
		if pagesWalked >= maxPaginationPages {
			return nil, total, fmt.Errorf("AWX pagination exceeded %d pages", maxPaginationPages)
		}
		resp, err := getJSON(cfg, next)
		if err != nil {
			return nil, 0, err
		}
		var pageBody awxPage
		if err := json.Unmarshal(resp.Body, &pageBody); err != nil {
			return nil, 0, fmt.Errorf("decode AWX pagination response: %w", err)
		}
		if pagesWalked == 0 {
			total = pageBody.Count
			if total < 0 || total > maxResults {
				return nil, total, fmt.Errorf("AWX result count %d exceeds bound %d", total, maxResults)
			}
		} else if pageBody.Count != total {
			return nil, total, fmt.Errorf("AWX result count changed during pagination")
		}
		if len(pageBody.Results) > awxPageSize {
			return nil, total, fmt.Errorf("AWX page exceeds the requested page size")
		}
		if len(all)+len(pageBody.Results) > maxResults {
			return nil, total, fmt.Errorf("AWX results exceed bound %d", maxResults)
		}
		if len(pageBody.Results) == 0 && pageBody.Next != "" {
			return nil, total, fmt.Errorf("AWX returned an empty non-terminal page")
		}
		all = append(all, pageBody.Results...)
		pagesWalked++

		// AWX returns `next` either as null or as a path like
		// "/api/v2/inventories/?page=2". We always strip the host so
		// the same host:port the operator configured is reused.
		rawNext := pageBody.Next
		next = relativizeAWXPath(rawNext)
		if rawNext != "" && next == "" {
			return nil, total, fmt.Errorf("AWX returned an invalid pagination link")
		}
	}
	if len(all) != total {
		return nil, total, fmt.Errorf("AWX pagination returned %d of %d results", len(all), total)
	}
	return all, total, nil
}

// relativizeAWXPath turns AWX's `next` URL into a base-URL-relative path so
// we never accidentally chase a redirect to a different host than the
// configured controller.
func relativizeAWXPath(next string) string {
	switch {
	case next == "":
		return ""
	case strings.HasPrefix(next, "/") && !strings.HasPrefix(next, "//"):
		return next
	case strings.HasPrefix(next, "https://"):
		i := strings.Index(next[len("https://"):], "/")
		if i < 0 {
			return ""
		}
		return next[len("https://")+i:]
	case strings.HasPrefix(next, "http://"):
		i := strings.Index(next[len("http://"):], "/")
		if i < 0 {
			return ""
		}
		return next[len("http://")+i:]
	default:
		return ""
	}
}

// listResultPayload is the wire shape every list verb returns inside
// Result.Details. The Elixir AwxClient parses this directly.
type listResultPayload struct {
	Verb    string            `json:"verb"`
	OK      bool              `json:"ok"`
	Count   int               `json:"count"`
	Pages   int               `json:"pages_walked"`
	Results []json.RawMessage `json:"results"`
	Extra   map[string]any    `json:"extra,omitempty"`
}

func encodeListPayload(verb string, results []json.RawMessage, total int, extra map[string]any) string {
	pages := (len(results) + 199) / 200
	if pages < 1 && len(results) > 0 {
		pages = 1
	}
	body, _ := json.Marshal(listResultPayload{
		Verb:    verb,
		OK:      true,
		Count:   total,
		Pages:   pages,
		Results: results,
		Extra:   extra,
	})
	return string(body)
}

type awxRowProjector func(json.RawMessage) (map[string]any, bool)

const (
	maxAWXCatalogNameBytes       = 512
	maxAWXTemplateDescription    = 8 * 1024
	maxAWXTemplateTagsBytes      = 4 * 1024
	maxAWXTemplateLimitBytes     = 16 * 1024
	maxAWXPlaybookPathBytes      = 1024
	maxAWXSurveyFields           = 100
	maxAWXSurveyQuestionBytes    = 512
	maxAWXSurveyDescriptionBytes = 4 * 1024
	maxAWXSurveyChoices          = 100
	maxAWXSurveyChoiceBytes      = 1024
	maxAWXSurveyChoicesBytes     = 16 * 1024
)

func projectAWXRows(rawRows []json.RawMessage, projector awxRowProjector) ([]json.RawMessage, error) {
	rows := make([]json.RawMessage, 0, len(rawRows))
	for _, raw := range rawRows {
		row, ok := projector(raw)
		if !ok {
			return nil, fmt.Errorf("AWX returned an invalid catalog row")
		}
		encoded, err := json.Marshal(row)
		if err != nil {
			return nil, fmt.Errorf("encode AWX catalog row")
		}
		rows = append(rows, encoded)
	}
	return rows, nil
}

func projectAWXInventory(raw json.RawMessage) (map[string]any, bool) {
	row, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	id, idOK := requiredRawInt(row["id"], 1, math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	kind, kindOK := rawString(row["kind"])
	totalHosts, totalOK := requiredRawInt(row["total_hosts"], 0, math.MaxInt32)
	organization, organizationOK, hasOrganization := optionalRawPositiveID(row["organization"])
	if !idOK || !nameOK || !kindOK || !stringIn(kind, "", "smart", "constructed") ||
		!totalOK || !organizationOK {
		return nil, false
	}
	safe := map[string]any{
		"id":          id,
		"name":        name,
		"kind":        kind,
		"total_hosts": totalHosts,
	}
	if hasOrganization {
		safe["organization"] = organization
	}
	return safe, true
}

func projectAWXHost(raw json.RawMessage) (map[string]any, bool) {
	row, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	id, idOK := requiredRawInt(row["id"], 1, math.MaxInt32)
	name, nameOK := rawString(row["name"])
	inventoryID, inventoryOK := requiredRawInt(row["inventory"], 1, math.MaxInt32)
	enabled, enabledOK := rawBool(row["enabled"])
	if !idOK || !nameOK || !literalAWXHostToken(name) || !inventoryOK || !enabledOK {
		return nil, false
	}
	return map[string]any{
		"id":        id,
		"name":      name,
		"inventory": inventoryID,
		"enabled":   enabled,
	}, true
}

func projectAWXInventoryGroup(raw json.RawMessage) (map[string]any, bool) {
	row, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	id, idOK := requiredRawInt(row["id"], 1, math.MaxInt32)
	name, nameOK := rawString(row["name"])
	if !idOK || !nameOK || !literalAWXHostToken(name) {
		return nil, false
	}
	return map[string]any{"id": id, "name": name}, true
}

func projectAWXProject(raw json.RawMessage) (map[string]any, bool) {
	row, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	id, idOK := requiredRawInt(row["id"], 1, math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	organization, organizationOK, hasOrganization := optionalRawPositiveID(row["organization"])
	status, statusOK := reviewedRawText(row["status"], 64, false)
	scmType, scmTypeOK := reviewedRawToken(row["scm_type"], 64, true)
	scmRevision, revisionOK := reviewedRawToken(row["scm_revision"], 128, true)
	updateOnLaunch, updateOK := projectUpdateOnLaunch(row)
	if !idOK || !nameOK || !organizationOK || !statusOK || !scmTypeOK ||
		!revisionOK || !updateOK {
		return nil, false
	}
	safe := map[string]any{
		"id":               id,
		"name":             name,
		"status":           status,
		"scm_type":         scmType,
		"scm_revision":     scmRevision,
		"update_on_launch": updateOnLaunch,
	}
	if hasOrganization {
		safe["organization"] = organization
	}
	return safe, true
}

func projectUpdateOnLaunch(row map[string]json.RawMessage) (bool, bool) {
	rawSCM, hasSCM := row["scm_update_on_launch"]
	rawLegacy, hasLegacy := row["update_on_launch"]
	if !hasSCM && !hasLegacy {
		return false, false
	}
	if hasSCM {
		value, ok := rawBool(rawSCM)
		if !ok {
			return false, false
		}
		if hasLegacy {
			legacy, legacyOK := rawBool(rawLegacy)
			if !legacyOK || legacy != value {
				return false, false
			}
		}
		return value, true
	}
	return rawBool(rawLegacy)
}

func projectAWXTemplate(raw json.RawMessage) (map[string]any, bool) {
	row, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	id, idOK := requiredRawInt(row["id"], 1, math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	description, descriptionOK, hasDescription := optionalReviewedRawText(
		row["description"], maxAWXTemplateDescription, true,
	)
	jobTags, tagsOK, hasTags := optionalReviewedRawText(row["job_tags"], maxAWXTemplateTagsBytes, true)
	limit, limitOK, hasLimit := optionalReviewedRawText(row["limit"], maxAWXTemplateLimitBytes, true)
	jobType, jobTypeOK := rawString(row["job_type"])
	playbook, playbookOK, hasPlaybook := optionalReviewedPlaybookPath(row["playbook"])
	projectID, projectOK, hasProject := optionalRawPositiveID(row["project"])
	inventoryID, inventoryOK, hasInventory := optionalRawPositiveID(row["inventory"])
	surveyEnabled, surveyOK := rawBool(row["survey_enabled"])
	askVariables, askVariablesOK := rawBool(row["ask_variables_on_launch"])
	askInventory, askInventoryOK := rawBool(row["ask_inventory_on_launch"])
	askLimit, askLimitOK := rawBool(row["ask_limit_on_launch"])
	askCredential, askCredentialOK := rawBool(row["ask_credential_on_launch"])
	if !idOK || !nameOK || !descriptionOK || !tagsOK || !limitOK ||
		!jobTypeOK || !stringIn(jobType, "run", "check") || !playbookOK ||
		!projectOK || !inventoryOK || !surveyOK || !askVariablesOK ||
		!askInventoryOK || !askLimitOK || !askCredentialOK {
		return nil, false
	}
	safe := map[string]any{
		"id":                       id,
		"name":                     name,
		"job_type":                 jobType,
		"survey_enabled":           surveyEnabled,
		"ask_variables_on_launch":  askVariables,
		"ask_inventory_on_launch":  askInventory,
		"ask_limit_on_launch":      askLimit,
		"ask_credential_on_launch": askCredential,
	}
	if hasDescription {
		safe["description"] = description
	}
	if hasTags {
		safe["job_tags"] = jobTags
	}
	if hasLimit {
		safe["limit"] = limit
	}
	if hasPlaybook {
		safe["playbook"] = playbook
	}
	if hasProject {
		safe["project"] = projectID
	}
	if hasInventory {
		safe["inventory"] = inventoryID
	}
	return safe, true
}

func rawObject(raw json.RawMessage) (map[string]json.RawMessage, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	var value map[string]json.RawMessage
	if err := json.Unmarshal(raw, &value); err != nil || value == nil {
		return nil, false
	}
	return value, true
}

func requiredRawInt(raw json.RawMessage, minValue, maxValue int64) (int, bool) {
	value, ok := rawInteger(raw, minValue, maxValue)
	return int(value), ok
}

func optionalRawPositiveID(raw json.RawMessage) (int, bool, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return 0, true, false
	}
	value, ok := requiredRawInt(raw, 1, math.MaxInt32)
	return value, ok, ok
}

func reviewedRawText(raw json.RawMessage, maxBytes int, allowEmpty bool) (string, bool) {
	value, ok := rawString(raw)
	return value, ok && boundedStaticText(value, maxBytes, allowEmpty)
}

func optionalReviewedRawText(
	raw json.RawMessage,
	maxBytes int,
	allowEmpty bool,
) (string, bool, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", true, false
	}
	value, ok := reviewedRawText(raw, maxBytes, allowEmpty)
	return value, ok, ok
}

func reviewedRawToken(raw json.RawMessage, maxBytes int, allowEmpty bool) (string, bool) {
	value, ok := reviewedRawText(raw, maxBytes, allowEmpty)
	if !ok {
		return "", false
	}
	for _, char := range []byte(value) {
		if (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || char == '.' || char == '_' ||
			char == '+' || char == '/' || char == '-' {
			continue
		}
		return "", false
	}
	return value, true
}

func optionalReviewedPlaybookPath(raw json.RawMessage) (string, bool, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", true, false
	}
	path, ok := reviewedRawText(raw, maxAWXPlaybookPathBytes, false)
	if !ok || strings.HasPrefix(path, "/") || strings.HasPrefix(path, "\\") ||
		strings.Contains(path, "\\") {
		return "", false, false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return "", false, false
		}
	}
	return path, true, true
}

func stringIn(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}

var reservedAWXSurveyVariables = [...]string{
	"allowed_callback_origin", "allowed_origin", "callback_manifest_sha256",
	"callback_operation", "callback_origin", "callback_phase",
	"callback_policy", "callback_response_policy_provider", "callback_state",
	"callback_url", "desired_state", "manifest_sha256", "operation",
	"phase", "remote_access_operation", "response_policy_provider",
	"serviceradar_dispatch_id", "serviceradar_snapshot_digest", "state",
	"group_names", "groups", "hostvars", "inventory_dir",
	"inventory_file", "inventory_hostname", "inventory_hostname_short",
	"omit", "play_hosts", "playbook_dir", "role_name", "role_path",
}

var sensitiveAWXSurveyVariableTokens = [...]string{
	"authorization", "bearer", "credential", "credentials",
	"passwd", "password", "secret", "token",
}

var sensitiveAWXSurveyVariableTokenPairs = [...]string{
	"access_key", "access_token", "api_key", "api_token",
	"bearer_token", "client_secret", "credential_value",
	"private_key",
}

// Compact compounds cover all-uppercase or otherwise unsegmentable spellings
// such as APIKEY. Token-level matching remains the primary classifier so safe
// names containing an unrelated word such as "tokenizer" stay allowed.
var sensitiveAWXSurveyVariableCompounds = [...]string{
	"accesskey", "accesstoken", "apikey", "apitoken",
	"bearertoken", "clientsecret", "credentialvalue",
	"privatekey",
}

func projectAWXSurvey(raw []byte) (map[string]any, bool) {
	root, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	if len(root) == 0 {
		return map[string]any{}, true
	}
	if value, present := root["name"]; present {
		if _, ok := reviewedRawText(value, maxAWXSurveyQuestionBytes, true); !ok {
			return nil, false
		}
	}
	if value, present := root["description"]; present {
		if _, ok := reviewedRawText(value, maxAWXSurveyDescriptionBytes, true); !ok {
			return nil, false
		}
	}
	var rawFields []json.RawMessage
	if err := json.Unmarshal(root["spec"], &rawFields); err != nil || len(rawFields) > maxAWXSurveyFields {
		return nil, false
	}
	fields := make([]map[string]any, 0, len(rawFields))
	seen := make(map[string]struct{}, len(rawFields))
	for _, rawField := range rawFields {
		field, variable, ok := projectAWXSurveyField(rawField)
		if !ok {
			return nil, false
		}
		normalized := strings.ToLower(variable)
		if _, duplicate := seen[normalized]; duplicate {
			return nil, false
		}
		seen[normalized] = struct{}{}
		fields = append(fields, field)
	}
	return map[string]any{"spec": fields}, true
}

func projectAWXSurveyField(raw json.RawMessage) (map[string]any, string, bool) {
	field, ok := rawObject(raw)
	if !ok {
		return nil, "", false
	}
	variable, variableOK := rawString(field["variable"])
	question, questionOK := reviewedRawText(field["question_name"], maxAWXSurveyQuestionBytes, true)
	fieldType, typeOK := rawString(field["type"])
	required, requiredOK := rawBool(field["required"])
	markerLength, marker := awxDispatchMarkerLength(variable)
	if !variableOK || (!marker && !reviewedAWXSurveyVariable(variable)) ||
		(marker && variable != strings.ToLower(variable)) || !questionOK || !typeOK ||
		!stringIn(fieldType, "text", "textarea", "integer", "float", "multiplechoice", "multiselect") ||
		!requiredOK {
		return nil, "", false
	}
	safe := map[string]any{
		"variable":      variable,
		"question_name": question,
		"type":          fieldType,
		"required":      required,
	}
	choices, choicesOK, hasChoices := projectAWXSurveyChoices(field["choices"], fieldType)
	min, minFloat, minOK, hasMin := optionalRawSurveyNumber(field["min"])
	max, maxFloat, maxOK, hasMax := optionalRawSurveyNumber(field["max"])
	description, descriptionOK, hasDescription := optionalReviewedRawText(
		field["question_description"], maxAWXSurveyDescriptionBytes, true,
	)
	if !choicesOK || !minOK || !maxOK || !descriptionOK || (hasMin && hasMax && minFloat > maxFloat) {
		return nil, "", false
	}
	if marker && (fieldType != "text" || !required || !hasMin || !hasMax ||
		minFloat != float64(markerLength) || maxFloat != float64(markerLength) ||
		!emptyAWXSurveyChoices(field["choices"]) || !emptyAWXSurveyDefault(field["default"])) {
		return nil, "", false
	}
	if hasChoices {
		safe["choices"] = choices
	}
	if hasMin {
		safe["min"] = min
	}
	if hasMax {
		safe["max"] = max
	}
	if hasDescription {
		safe["question_description"] = description
	}
	return safe, variable, true
}

func awxDispatchMarkerLength(value string) (int, bool) {
	switch strings.ToLower(value) {
	case "serviceradar_dispatch_id":
		return 36, true
	case "serviceradar_snapshot_digest":
		return 64, true
	default:
		return 0, false
	}
}

func emptyAWXSurveyChoices(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return true
	}
	if text, ok := rawString(raw); ok {
		return text == ""
	}
	var values []string
	return json.Unmarshal(raw, &values) == nil && len(values) == 0
}

func emptyAWXSurveyDefault(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return true
	}
	value, ok := rawString(raw)
	return ok && value == ""
}

func reviewedAWXSurveyVariable(value string) bool {
	if len(value) == 0 || len(value) > 128 ||
		!((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z') || value[0] == '_') {
		return false
	}
	for _, char := range []byte(value[1:]) {
		if (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || char == '_' {
			continue
		}
		return false
	}
	normalized := strings.ToLower(value)
	if strings.HasPrefix(normalized, "ansible_") {
		return false
	}
	if stringIn(normalized, reservedAWXSurveyVariables[:]...) {
		return false
	}
	compact := strings.ReplaceAll(normalized, "_", "")
	for _, compound := range sensitiveAWXSurveyVariableCompounds {
		if strings.Contains(compact, compound) {
			return false
		}
	}
	tokens := awxSurveyVariableTokens(value)
	for index, token := range tokens {
		if stringIn(token, sensitiveAWXSurveyVariableTokens[:]...) {
			return false
		}
		if index+1 < len(tokens) {
			if stringIn(token+"_"+tokens[index+1], sensitiveAWXSurveyVariableTokenPairs[:]...) {
				return false
			}
		}
	}
	return true
}

// awxSurveyVariableTokens canonicalizes the ASCII identifier grammar above in
// the same way as the core binding validator: underscores, camel-case/acronym
// transitions, and letter/digit transitions are all token boundaries. Keeping
// this token contract identical at catalog import and launch review prevents a
// controller from spelling a secret field differently at the two boundaries.
func awxSurveyVariableTokens(value string) []string {
	tokens := make([]string, 0, 4)
	start := 0
	flush := func(end int) {
		if start < end {
			tokens = append(tokens, strings.ToLower(value[start:end]))
		}
	}

	for index := 0; index < len(value); index++ {
		current := value[index]
		if current == '_' {
			flush(index)
			start = index + 1
			continue
		}
		if index == start {
			continue
		}

		previous := value[index-1]
		currentUpper := current >= 'A' && current <= 'Z'
		previousUpper := previous >= 'A' && previous <= 'Z'
		previousLower := previous >= 'a' && previous <= 'z'
		currentDigit := current >= '0' && current <= '9'
		previousDigit := previous >= '0' && previous <= '9'
		nextLower := index+1 < len(value) && value[index+1] >= 'a' && value[index+1] <= 'z'

		boundary := currentUpper && (previousLower || previousDigit || (previousUpper && nextLower))
		boundary = boundary || currentDigit != previousDigit
		if boundary {
			flush(index)
			start = index
		}
	}
	flush(len(value))
	return tokens
}

func projectAWXSurveyChoices(raw json.RawMessage, fieldType string) (any, bool, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, true, false
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		if len(text) > maxAWXSurveyChoicesBytes || !utf8.ValidString(text) {
			return nil, false, false
		}
		if text == "" {
			return text, true, true
		}
		if !stringIn(fieldType, "multiplechoice", "multiselect") {
			return nil, false, false
		}
		parts := strings.FieldsFunc(text, func(char rune) bool { return char == '\n' || char == ',' })
		if len(parts) == 0 || len(parts) > maxAWXSurveyChoices {
			return nil, false, false
		}
		choices := make([]string, 0, len(parts))
		for _, part := range parts {
			choice := strings.TrimSpace(part)
			if !safeStaticText(choice, maxAWXSurveyChoiceBytes) {
				return nil, false, false
			}
			choices = append(choices, choice)
		}
		return choices, true, true
	}
	var values []string
	if json.Unmarshal(raw, &values) != nil || len(values) > maxAWXSurveyChoices ||
		(len(values) > 0 && !stringIn(fieldType, "multiplechoice", "multiselect")) {
		return nil, false, false
	}
	for _, value := range values {
		if !safeStaticText(value, maxAWXSurveyChoiceBytes) {
			return nil, false, false
		}
	}
	return values, true, true
}

func optionalRawSurveyNumber(raw json.RawMessage) (json.Number, float64, bool, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", 0, true, false
	}
	if len(raw) > 64 {
		return "", 0, false, false
	}
	value := json.Number(string(raw))
	parsed, err := strconv.ParseFloat(string(value), 64)
	if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) {
		return "", 0, false, false
	}
	return value, parsed, true, true
}

func runListInventories(cfg Config) *sdk.Result {
	results, total, err := listAWXPath(cfg, "/api/v2/inventories/?page_size=200")
	if err != nil {
		return errorResult("awx.list_inventories", err)
	}
	results, err = projectAWXRows(results, projectAWXInventory)
	if err != nil {
		return errorResult("awx.list_inventories", err)
	}
	return sdk.Ok(fmt.Sprintf("listed %d inventories", total)).
		WithDetails(encodeListPayload("awx.list_inventories", results, total, nil)).
		WithLabel("verb", "awx.list_inventories")
}

func runListHosts(cfg Config) *sdk.Result {
	inventoryID, ok := argInt(cfg.Args, "inventory_id")
	if !ok || inventoryID <= 0 {
		return errorResult("awx.list_hosts", fmt.Errorf("args.inventory_id is required"))
	}
	path := fmt.Sprintf("/api/v2/inventories/%d/hosts/?page_size=200", inventoryID)
	results, total, err := listAWXPath(cfg, path)
	if err != nil {
		return errorResult("awx.list_hosts", err)
	}
	results, err = projectAWXRows(results, projectAWXHost)
	if err != nil {
		return errorResult("awx.list_hosts", err)
	}
	extra := map[string]any{"inventory_id": inventoryID}
	return sdk.Ok(fmt.Sprintf("listed %d hosts in inventory %d", total, inventoryID)).
		WithDetails(encodeListPayload("awx.list_hosts", results, total, extra)).
		WithLabel("verb", "awx.list_hosts")
}

// runListInventoryGroups handles `awx.list_inventory_groups` by returning the
// exact bounded set from /api/v2/inventories/{id}/groups/. The hardened launch
// planner uses group names to reject literal host tokens that AWX could instead
// interpret as a group. It must also independently reject Ansible's reserved
// `all` and `ungrouped` tokens; this endpoint does not synthesize them.
func runListInventoryGroups(cfg Config) *sdk.Result {
	inventoryID, ok := argInt(cfg.Args, "inventory_id")
	if !ok || inventoryID <= 0 {
		return errorResult("awx.list_inventory_groups", fmt.Errorf("args.inventory_id is required"))
	}
	maxGroups := maxPaginatedRows
	if _, present := cfg.Args["max_groups"]; present {
		maxGroups, ok = argInt(cfg.Args, "max_groups")
		if !ok || maxGroups <= 0 || maxGroups > maxPaginatedRows {
			return errorResult(
				"awx.list_inventory_groups",
				fmt.Errorf("args.max_groups must be an integer between 1 and %d", maxPaginatedRows),
			)
		}
	}
	path := fmt.Sprintf("/api/v2/inventories/%d/groups/?page_size=200&order_by=id", inventoryID)
	results, total, err := listAWXPathBounded(cfg, path, maxGroups)
	if err != nil {
		return errorResult("awx.list_inventory_groups", err)
	}
	safeResults, err := projectAWXRows(results, projectAWXInventoryGroup)
	if err != nil {
		return errorResult("awx.list_inventory_groups", err)
	}
	extra := map[string]any{"inventory_id": inventoryID}
	return sdk.Ok(fmt.Sprintf("listed %d groups in inventory %d", total, inventoryID)).
		WithDetails(encodeListPayload("awx.list_inventory_groups", safeResults, total, extra)).
		WithLabel("verb", "awx.list_inventory_groups")
}

func runListProjects(cfg Config) *sdk.Result {
	results, total, err := listAWXPath(cfg, "/api/v2/projects/?page_size=200")
	if err != nil {
		return errorResult("awx.list_projects", err)
	}
	results, err = projectAWXRows(results, projectAWXProject)
	if err != nil {
		return errorResult("awx.list_projects", err)
	}
	return sdk.Ok(fmt.Sprintf("listed %d projects", total)).
		WithDetails(encodeListPayload("awx.list_projects", results, total, nil)).
		WithLabel("verb", "awx.list_projects")
}

func runListTemplates(cfg Config) *sdk.Result {
	results, total, err := listAWXPath(cfg, "/api/v2/job_templates/?page_size=200")
	if err != nil {
		return errorResult("awx.list_templates", err)
	}
	results, err = projectAWXRows(results, projectAWXTemplate)
	if err != nil {
		return errorResult("awx.list_templates", err)
	}
	return sdk.Ok(fmt.Sprintf("listed %d job templates", total)).
		WithDetails(encodeListPayload("awx.list_templates", results, total, nil)).
		WithLabel("verb", "awx.list_templates")
}

// runFetchTemplate fetches /api/v2/job_templates/{id}/ AND the corresponding
// /survey_spec/, merging both into a single payload so the catalog sync
// worker only needs one verb call per template.
func runFetchTemplate(cfg Config) *sdk.Result {
	templateID, ok := argInt(cfg.Args, "template_id")
	if !ok || templateID <= 0 || templateID > math.MaxInt32 {
		return errorResult("awx.fetch_template", fmt.Errorf("args.template_id is required"))
	}

	tmplResp, err := getJSON(cfg, fmt.Sprintf("/api/v2/job_templates/%d/", templateID))
	if err != nil {
		return errorResult("awx.fetch_template", err)
	}
	tmpl, ok := projectAWXTemplate(tmplResp.Body)
	if !ok {
		return errorResult("awx.fetch_template", fmt.Errorf("AWX returned an invalid job template"))
	}
	if returnedID, ok := tmpl["id"].(int); !ok || returnedID != templateID {
		return errorResult("awx.fetch_template", fmt.Errorf("AWX returned a mismatched job template"))
	}

	// Survey spec is on a sub-resource; AWX returns 200 with `{}` when no
	// survey is defined. A 404 is also tolerated for older AWX versions.
	survey := map[string]any{}
	surveyResp, notFound, err := getJSONAllowNotFound(
		cfg,
		fmt.Sprintf("/api/v2/job_templates/%d/survey_spec/", templateID),
	)
	if err != nil {
		return errorResult("awx.fetch_template", err)
	}
	if !notFound {
		survey, ok = projectAWXSurvey(surveyResp.Body)
		if !ok {
			return errorResult("awx.fetch_template", fmt.Errorf("AWX returned an invalid survey"))
		}
	}

	payload := map[string]any{
		"verb":        "awx.fetch_template",
		"ok":          true,
		"template_id": templateID,
		"template":    tmpl,
		"survey_spec": survey,
	}
	body, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("fetched job template %d", templateID)).
		WithDetails(string(body)).
		WithLabel("verb", "awx.fetch_template")
}

// argInt extracts an integer from an `Args` map. JSON numbers come back as
// float64 in Go's default unmarshaler; accept both.
func argInt(args map[string]any, key string) (int, bool) {
	v, ok := args[key]
	if !ok {
		return 0, false
	}
	switch n := v.(type) {
	case float64:
		if math.IsNaN(n) || math.IsInf(n, 0) || n != math.Trunc(n) {
			return 0, false
		}
		converted := int(n)
		if float64(converted) != n {
			return 0, false
		}
		return converted, true
	case int:
		return n, true
	case int64:
		converted := int(n)
		if int64(converted) != n {
			return 0, false
		}
		return converted, true
	case json.Number:
		parsed, err := strconv.ParseInt(string(n), 10, 64)
		if err != nil {
			return 0, false
		}
		converted := int(parsed)
		if int64(converted) != parsed {
			return 0, false
		}
		return converted, true
	}
	return 0, false
}

func argIntSlice(args map[string]any, key string) ([]int, bool) {
	raw, ok := args[key]
	if !ok {
		return nil, false
	}
	switch values := raw.(type) {
	case []int:
		return append([]int(nil), values...), true
	case []any:
		out := make([]int, 0, len(values))
		for _, rawValue := range values {
			value, ok := argInt(map[string]any{"value": rawValue}, "value")
			if !ok {
				return nil, false
			}
			out = append(out, value)
		}
		return out, true
	default:
		return nil, false
	}
}

// errorResult builds a structured CRITICAL result for a verb call that
// failed. The Details payload is what AwxClient parses to surface a typed
// error to the LiveView; raw error strings are sanitized so URLs / tokens
// don't leak.
func errorResult(verb string, err error) *sdk.Result {
	msg := sanitizeError(err)
	payload := map[string]any{
		"verb":  verb,
		"ok":    false,
		"error": msg,
	}
	body, _ := json.Marshal(payload)
	return sdk.Critical(verb+": "+msg).WithDetails(string(body)).WithLabel("verb", verb)
}

// getJSON performs an authenticated GET against AWX and returns the
// (raw) HTTP response. Body inspection is the caller's job.
func getJSON(cfg Config, path string) (*sdk.HTTPResponse, error) {
	timeoutMS := cfg.TimeoutMS
	if timeoutMS <= 0 {
		timeoutMS = defaultTimeoutMS
	}

	req := sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    strings.TrimRight(cfg.BaseURL, "/") + path,
		Headers: map[string]string{
			"Authorization": "Bearer " + cfg.APIToken,
			"Accept":        "application/json",
		},
		TimeoutMS:          timeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}

	resp, err := awxHTTP.Do(req)
	if err != nil {
		return nil, errAWXRequestFailed
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return nil, errAWXRequestFailed
	}
	return resp, nil
}

func getJSONAllowNotFound(cfg Config, path string) (*sdk.HTTPResponse, bool, error) {
	timeoutMS := cfg.TimeoutMS
	if timeoutMS <= 0 {
		timeoutMS = defaultTimeoutMS
	}

	req := sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    strings.TrimRight(cfg.BaseURL, "/") + path,
		Headers: map[string]string{
			"Authorization": "Bearer " + cfg.APIToken,
			"Accept":        "application/json",
		},
		TimeoutMS:          timeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}
	resp, err := awxHTTP.Do(req)
	if err != nil {
		return nil, false, errAWXRequestFailed
	}
	if resp.Status == http.StatusNotFound {
		return resp, true, nil
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return nil, false, errAWXRequestFailed
	}
	return resp, false, nil
}

// sanitizeError deliberately collapses all upstream text to a fixed message.
// HTTP/client errors can contain credentials, response bodies, query strings,
// or multiple internal URLs in forms that cannot be safely recovered with a
// blacklist. Structural status is carried separately by each verb.
func sanitizeError(err error) string {
	if err == nil {
		return ""
	}
	if err == errAWXRequestFailed {
		return errAWXRequestFailed.Error()
	}
	raw := err.Error()
	s := strings.TrimSpace(raw)
	if raw != s || !boundedStaticText(s, 512, false) {
		return "AWX command rejected"
	}
	return s
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

// primeTinyGoJSON registers types we'll marshal so TinyGo's reflection-free
// JSON support pulls them in. Mirrors the proxmox plugin's pattern.
func primeTinyGoJSON() {
	_, _ = json.Marshal(map[string]any{"t": time.Time{}})
}

// InventorySyncControllerConfig describes one AWX controller in the scheduled
// `inventory_sync` entrypoint. The assignment carries only the host-injected
// sentinel; the trusted agent retains resolved API tokens outside Wasm memory.
type InventorySyncControllerConfig struct {
	// ControllerID is the ServiceRadar AnsibleController.id. We embed
	// it in DeviceID so DIRE can attribute hosts back to the right
	// controller even when the AWX host_id is reused across instances.
	ControllerID string `json:"controller_id"`

	// ControllerName is operator-facing; lands in DiscoveredDevice
	// labels and metadata for searchability.
	ControllerName string `json:"controller_name,omitempty"`

	BaseURL  string `json:"base_url"`
	APIToken string `json:"api_token"`

	TimeoutMS          int  `json:"timeout_ms,omitempty"`
	InsecureSkipVerify bool `json:"insecure_skip_verify,omitempty"`
}

// InventorySyncConfig drives the scheduled `inventory_sync` entrypoint.
// New assignments carry one controller list per agent. The legacy top-level
// fields are still accepted so already-delivered single-controller assignments
// continue to run during rollout.
type InventorySyncConfig struct {
	Controllers []InventorySyncControllerConfig `json:"controllers,omitempty"`

	ControllerID       string `json:"controller_id,omitempty"`
	ControllerName     string `json:"controller_name,omitempty"`
	BaseURL            string `json:"base_url,omitempty"`
	APIToken           string `json:"api_token,omitempty"`
	TimeoutMS          int    `json:"timeout_ms,omitempty"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify,omitempty"`
}

func (cfg InventorySyncConfig) controllerConfigs() []InventorySyncControllerConfig {
	if len(cfg.Controllers) > 0 {
		return cfg.Controllers
	}

	if strings.TrimSpace(cfg.ControllerID) == "" &&
		strings.TrimSpace(cfg.ControllerName) == "" &&
		strings.TrimSpace(cfg.BaseURL) == "" &&
		strings.TrimSpace(cfg.APIToken) == "" {
		return nil
	}

	return []InventorySyncControllerConfig{{
		ControllerID:       cfg.ControllerID,
		ControllerName:     cfg.ControllerName,
		BaseURL:            cfg.BaseURL,
		APIToken:           cfg.APIToken,
		TimeoutMS:          cfg.TimeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	}}
}

// asConfig returns a request-shaped Config for reusing getJSON / listAWXPath.
func (c InventorySyncControllerConfig) asConfig() Config {
	return Config{
		BaseURL:            c.BaseURL,
		APIToken:           c.APIToken,
		TimeoutMS:          c.TimeoutMS,
		InsecureSkipVerify: c.InsecureSkipVerify,
	}
}

//export inventory_sync
func inventory_sync() {
	primeTinyGoJSONInventory()

	_ = sdk.Execute(func() (*sdk.Result, error) {
		var cfg InventorySyncConfig
		if err := sdk.LoadConfig(&cfg); err != nil {
			return sdk.Unknown("AWX inventory_sync configuration could not be loaded"), nil
		}
		if err := validateInventorySyncConfig(cfg); err != nil {
			return sdk.Unknown("AWX inventory_sync configuration invalid: " + err.Error()), nil
		}
		return runInventorySync(cfg), nil
	})
}

func validateInventorySyncConfig(cfg InventorySyncConfig) error {
	controllers := cfg.controllerConfigs()
	if len(controllers) == 0 {
		return fmt.Errorf("controllers is required")
	}

	for i, controller := range controllers {
		if strings.TrimSpace(controller.BaseURL) == "" {
			return fmt.Errorf("controllers[%d].base_url is required", i)
		}
		if controller.APIToken != awxInventoryHostCredentialSentinel {
			return fmt.Errorf("controllers[%d].api_token host sentinel is required", i)
		}
		if strings.TrimSpace(controller.ControllerID) == "" {
			return fmt.Errorf("controllers[%d].controller_id is required", i)
		}
	}
	return nil
}

// awxInventoryRow is the subset of /api/v2/inventories/ we care about.
type awxInventoryRow struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	Description  string `json:"description"`
	Kind         string `json:"kind"`
	Organization int    `json:"organization"`
	TotalHosts   int    `json:"total_hosts"`
}

// awxHostRow is the subset of /api/v2/inventories/{id}/hosts/ we care about.
type awxHostRow struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Inventory   int    `json:"inventory"`
	Enabled     bool   `json:"enabled"`
	InstanceID  string `json:"instance_id"`
	Variables   string `json:"variables"`
}

// runInventorySync walks every inventory + host on each configured controller.
// It emits one DeviceDiscovery aggregate per controller; the agent → gateway →
// DIRE pipeline carries those envelopes the rest of the way.
func runInventorySync(cfg InventorySyncConfig) *sdk.Result {
	controllers := cfg.controllerConfigs()
	if len(controllers) == 1 {
		return runInventorySyncController(controllers[0])
	}

	totalHosts := 0
	totalInventories := 0
	failures := 0
	result := sdk.Ok("")

	for _, controller := range controllers {
		controllerResult := runInventorySyncController(controller)
		if controllerResult.Status == sdk.StatusCritical {
			failures++
			continue
		}

		for _, discovery := range controllerResult.DeviceDiscovery {
			totalHosts += len(discovery.Devices)
			totalInventories += intFromDiscoveryMetadata(discovery.Metadata, "inventory_count")
			result.AddDeviceDiscovery(discovery)
		}
	}

	summary := fmt.Sprintf(
		"AWX inventory_sync: %d hosts across %d inventories on %d/%d controllers",
		totalHosts,
		totalInventories,
		len(controllers)-failures,
		len(controllers),
	)

	if failures == len(controllers) {
		result = sdk.Critical(summary)
	} else {
		// Partial success stays StatusOK so the healthy controllers'
		// DeviceDiscovery is never gated out of ingestion by a non-OK status;
		// the degradation is surfaced via the summary and the
		// controllers_failed label rather than by failing the whole check.
		result.SetSummary(summary)
	}

	result.WithLabel("controllers", strconv.Itoa(len(controllers)))
	result.WithLabel("controllers_failed", strconv.Itoa(failures))
	result.WithLabel("inventories", strconv.Itoa(totalInventories))
	result.WithLabel("hosts", strconv.Itoa(totalHosts))
	return result
}

func runInventorySyncController(cfg InventorySyncControllerConfig) *sdk.Result {
	now := time.Now().UTC()
	sourceGeneration := now.UnixNano()
	discovery := sdk.NewDeviceDiscovery("awx")
	discovery.ObservedAt = now.Format(time.RFC3339Nano)
	discovery.CollectionID = fmt.Sprintf("awx-%s-%d", cfg.ControllerID, sourceGeneration)
	if discovery.Metadata == nil {
		discovery.Metadata = map[string]any{}
	}
	discovery.Metadata["controller_id"] = cfg.ControllerID
	discovery.Metadata["source_generation"] = sourceGeneration
	if cfg.ControllerName != "" {
		discovery.Metadata["controller_name"] = cfg.ControllerName
	}

	cmdCfg := cfg.asConfig()
	invRows, _, err := listAWXPath(cmdCfg, "/api/v2/inventories/?page_size=200")
	if err != nil {
		return sdk.Critical("AWX inventory_sync failed listing inventories: " + sanitizeError(err))
	}

	totalHosts := 0
	totalInventories := 0
	complete := true
	for _, row := range invRows {
		var inv awxInventoryRow
		if err := json.Unmarshal(row, &inv); err != nil {
			complete = false
			continue
		}
		if inv.ID <= 0 {
			complete = false
			continue
		}
		totalInventories++

		hostsPath := fmt.Sprintf("/api/v2/inventories/%d/hosts/?page_size=200", inv.ID)
		hostRows, _, err := listAWXPath(cmdCfg, hostsPath)
		if err != nil {
			// Per-inventory failure: continue with what we have, but
			// stash a metadata note so DIRE can see partial coverage.
			discovery.Metadata["error_inventory_"+strconv.Itoa(inv.ID)] = sanitizeError(err)
			complete = false
			continue
		}

		for _, hostRow := range hostRows {
			var host awxHostRow
			if err := json.Unmarshal(hostRow, &host); err != nil {
				complete = false
				continue
			}
			if host.ID <= 0 || host.Inventory != inv.ID {
				complete = false
				continue
			}
			discovery.AddDevice(buildDiscoveredHost(cfg, inv, host))
			totalHosts++
		}
	}
	discovery.Metadata["inventory_count"] = totalInventories
	discovery.Metadata["complete"] = complete
	discovery.Metadata["source_fingerprint"] = inventorySourceFingerprint(cfg.ControllerID, discovery.Devices)

	summary := fmt.Sprintf(
		"AWX inventory_sync: %d hosts across %d inventories on %s",
		totalHosts, totalInventories, nonEmpty(cfg.ControllerName, cfg.ControllerID),
	)

	result := sdk.Ok(summary)
	result.WithDeviceDiscovery(*discovery)
	result.WithLabel("controller_id", cfg.ControllerID)
	result.WithLabel("inventories", strconv.Itoa(totalInventories))
	result.WithLabel("hosts", strconv.Itoa(totalHosts))
	return result
}

func inventorySourceFingerprint(controllerID string, devices []sdk.DiscoveredDevice) string {
	ordered := append([]sdk.DiscoveredDevice(nil), devices...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].DeviceID < ordered[j].DeviceID
	})

	canonical, err := json.Marshal(struct {
		ControllerID string                 `json:"controller_id"`
		Devices      []sdk.DiscoveredDevice `json:"devices"`
	}{ControllerID: controllerID, Devices: ordered})
	if err != nil {
		canonical = []byte(controllerID)
	}
	digest := sha256.Sum256(canonical)
	return fmt.Sprintf("sha256:%x", digest[:])
}

func intFromDiscoveryMetadata(metadata map[string]any, key string) int {
	switch value := metadata[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case float64:
		return int(value)
	case string:
		parsed, _ := strconv.Atoi(value)
		return parsed
	default:
		return 0
	}
}

// buildDiscoveredHost maps one AWX host row to a DiscoveredDevice. The
// `Metadata.awx` block carries the controller_id, inventory_id, host_id, and
// host_name that AnsibleController/PlaybookRunTarget joins resolve against.
func buildDiscoveredHost(cfg InventorySyncControllerConfig, inv awxInventoryRow, host awxHostRow) sdk.DiscoveredDevice {
	enabled := host.Enabled

	hostname := host.Name
	ansibleHost := extractAnsibleHostFromVariables(host.Variables)
	ip := ""
	if ansibleHost != "" {
		if isProbablyIP(ansibleHost) {
			ip = ansibleHost
		} else if hostname == "" {
			hostname = ansibleHost
		}
	}

	integrationID := awxIntegrationID(cfg.ControllerID, host.ID)

	return sdk.DiscoveredDevice{
		DeviceID:    fmt.Sprintf("awx:%s:host:%d", cfg.ControllerID, host.ID),
		Hostname:    hostname,
		IP:          ip,
		VendorName:  "Ansible",
		Type:        "host",
		Role:        "ansible_host",
		Status:      hostStatusString(host.Enabled),
		IsAvailable: &enabled,
		Labels: map[string]string{
			"provider":      "awx",
			"controller_id": cfg.ControllerID,
		},
		Metadata: awxHostMetadata(cfg, inv, host, integrationID, hostname, ansibleHost),
	}
}

// awxHostMetadata carries the AWX join keys plus the identity channels the
// inventory ingestor reads: `integration_id` overrides the hostname-derived key
// it would otherwise mint, `legacy_integration_ids` bridges rows already
// registered under that old key, and `mac_addresses` is the only hardware
// evidence AWX can supply. All three are looked up under `metadata`, not at the
// top level -- Sync.Normalize rebuilds a fixed-key map and a top-level
// `mac_addresses` would be dropped.
func awxHostMetadata(
	cfg InventorySyncControllerConfig,
	inv awxInventoryRow,
	host awxHostRow,
	integrationID string,
	hostname string,
	ansibleHost string,
) map[string]any {
	metadata := map[string]any{
		"awx": map[string]any{
			"controller_id":   cfg.ControllerID,
			"controller_name": cfg.ControllerName,
			"inventory_id":    inv.ID,
			"inventory_name":  inv.Name,
			"host_id":         host.ID,
			"host_name":       host.Name,
			"description":     host.Description,
			"instance_id":     host.InstanceID,
			"ansible_host":    ansibleHost,
		},
	}

	if integrationID != "" {
		metadata["integration_id"] = integrationID

		if legacy := awxLegacyIDs(hostname, host.Name, integrationID); len(legacy) > 0 {
			metadata["legacy_integration_ids"] = legacy
		}
	}

	if macs := awxHostMACs(host.Variables); len(macs) > 0 {
		metadata["mac_addresses"] = macs
	}

	return metadata
}

func hostStatusString(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
}

// extractAnsibleHostFromVariables pulls `ansible_host` (or
// `ansible_ssh_host` legacy) from an AWX host's `variables` blob. AWX
// returns this as either a YAML or JSON string. We try JSON first, then
// fall back to a simple line-by-line YAML scan — full YAML parsing in
// TinyGo isn't ergonomic and we only need this one key.
func extractAnsibleHostFromVariables(variables string) string {
	if variables == "" {
		return ""
	}
	trimmed := strings.TrimSpace(variables)
	if strings.HasPrefix(trimmed, "{") {
		var asJSON map[string]any
		if err := json.Unmarshal([]byte(trimmed), &asJSON); err == nil {
			for _, key := range []string{"ansible_host", "ansible_ssh_host"} {
				if v, ok := asJSON[key].(string); ok && v != "" {
					return v
				}
			}
		}
	}
	for _, line := range strings.Split(trimmed, "\n") {
		line = strings.TrimSpace(line)
		for _, key := range []string{"ansible_host:", "ansible_ssh_host:"} {
			if strings.HasPrefix(line, key) {
				v := strings.TrimSpace(strings.TrimPrefix(line, key))
				// Strip optional quotes and inline comments.
				if i := strings.Index(v, "#"); i >= 0 {
					v = strings.TrimSpace(v[:i])
				}
				v = strings.Trim(v, "\"'")
				if v != "" {
					return v
				}
			}
		}
	}
	return ""
}

// isProbablyIP returns true for trivial IPv4 dotted-quads or IPv6 strings
// without trying to be a real parser. Good enough for routing the value
// into DiscoveredDevice.IP vs DiscoveredDevice.Hostname.
func isProbablyIP(s string) bool {
	if strings.Contains(s, ":") {
		// Crude IPv6 check: contains a colon and at least one hex char.
		for _, r := range s {
			if (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') || (r >= '0' && r <= '9') || r == ':' {
				continue
			}
			return false
		}
		return true
	}
	// IPv4: four dotted decimal octets.
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

func primeTinyGoJSONInventory() {
	_, _ = json.Marshal(awxInventoryRow{})
	_, _ = json.Marshal(awxHostRow{})
}

// main is required by TinyGo's wasi target even though run_check /
// inventory_sync are the real exports. Mirrors proxmox/main.go.
func main() {}
