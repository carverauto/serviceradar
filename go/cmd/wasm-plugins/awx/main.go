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
// The plugin holds no per-controller state. Each invocation reads its
// `base_url` and `api_token` from the config the agent injected (which it
// resolved from the credential broker grant carried in the CommandRequest
// or assignment). See openspec change `add-ansible-integration` for the
// full design.
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

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

// awxHTTP is package-level so tests can swap it for a fake.
var awxHTTP httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

type httpClient interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

// Config is what the agent runtime hands to the plugin via get_config.
//
// The agent populates `APIToken` from the credential broker grant that
// rode in on the CommandRequest (or the inventory_sync assignment). The
// plugin never sees a broker grant ref — by the time we're invoked, the
// secret is resolved.
type Config struct {
	// BaseURL is the AWX/AAP base URL, e.g. https://awx.internal.example.com.
	BaseURL string `json:"base_url"`

	// APIToken is the AWX OAuth2 access token, sent as `Authorization: Bearer …`.
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

const defaultTimeoutMS = 15_000

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

	switch verb {
	case "awx.ping":
		return runPing(cfg)
	case "awx.list_inventories":
		return runListInventories(cfg)
	case "awx.list_hosts":
		return runListHosts(cfg)
	case "awx.list_inventory_groups":
		return runListInventoryGroups(cfg)
	case "awx.list_projects":
		return runListProjects(cfg)
	case "awx.list_templates":
		return runListTemplates(cfg)
	case "awx.fetch_template":
		return runFetchTemplate(cfg)
	case "awx.current_user":
		return runCurrentUser(cfg)
	case "awx.launch_job":
		return runLaunchJob(cfg)
	case "awx.create_callback_credential":
		return runCreateCallbackCredential(cfg)
	case "awx.fetch_callback_credential":
		return runFetchCallbackCredential(cfg)
	case "awx.delete_callback_credential":
		return runDeleteCallbackCredential(cfg)
	case "awx.fetch_job":
		return runFetchJob(cfg)
	case "awx.list_recent_jobs":
		return runListRecentJobs(cfg)
	case "awx.fetch_job_host_summaries":
		return runFetchJobHostSummaries(cfg)
	case "awx.cancel_job":
		return runCancelJob(cfg)
	case "awx.fetch_events_for_jobs":
		return runFetchEventsForJobs(cfg)
	default:
		return sdk.Critical(fmt.Sprintf("unknown verb %q", verb))
	}
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

var allowedCreateCallbackCredentialArgs = map[string]struct{}{
	"credential_type_id": {},
	"organization_id":    {},
	"credential_name":    {},
	"injector_sha256":    {},
}

var allowedFetchCallbackCredentialArgs = map[string]struct{}{
	"credential_type_id": {},
	"organization_id":    {},
	"credential_name":    {},
}

var allowedDeleteCallbackCredentialArgs = map[string]struct{}{
	"credential_id":      {},
	"credential_type_id": {},
	"organization_id":    {},
	"credential_name":    {},
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
	if err := validateExactArgs(cfg.Args, allowedCreateCallbackCredentialArgs); err != nil {
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
	if err := validateExactArgs(cfg.Args, allowedFetchCallbackCredentialArgs); err != nil {
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

type awxCallbackCredentialTypeField struct {
	ID     string `json:"id"`
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

	var inputs struct {
		Fields   []awxCallbackCredentialTypeField `json:"fields"`
		Required []string                         `json:"required"`
	}
	if err := json.Unmarshal(raw.Inputs, &inputs); err != nil {
		return normalizedCallbackCredentialType{}, fmt.Errorf("decode callback credential type inputs: %w", err)
	}
	if len(inputs.Fields) != len(callbackCredentialInputKeys) || len(inputs.Required) != len(callbackCredentialInputKeys) {
		return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type inputs do not match the reviewed contract")
	}
	expectedSecret := map[string]bool{
		"callback_grant":           true,
		"callback_idempotency_key": true,
	}
	seenFields := make(map[string]struct{}, len(inputs.Fields))
	for _, field := range inputs.Fields {
		secret := expectedSecret[field.ID]
		if field.Type != "string" || field.Secret != secret {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type field %q is unreviewed", field.ID)
		}
		if _, duplicate := seenFields[field.ID]; duplicate {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type contains duplicate fields")
		}
		seenFields[field.ID] = struct{}{}
	}
	for _, key := range callbackCredentialInputKeys {
		if _, present := seenFields[key]; !present {
			return normalizedCallbackCredentialType{}, fmt.Errorf("callback credential type is missing field %q", key)
		}
	}
	sort.Slice(inputs.Fields, func(i, j int) bool { return inputs.Fields[i].ID < inputs.Fields[j].ID })
	sort.Strings(inputs.Required)
	expectedRequired := append([]string(nil), callbackCredentialInputKeys[:]...)
	sort.Strings(expectedRequired)
	if !stringSlicesEqual(inputs.Required, expectedRequired) {
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
		Fields:           inputs.Fields,
		Required:         inputs.Required,
		Environment:      environment,
	}, nil
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
	if err := validateExactArgs(cfg.Args, allowedDeleteCallbackCredentialArgs); err != nil {
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

func validateExactArgs(args map[string]any, allowed map[string]struct{}) error {
	for key := range args {
		if _, ok := allowed[key]; !ok {
			return fmt.Errorf("args.%s is not allowed", key)
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

var allowedLaunchArgs = map[string]struct{}{
	"template_id":              {},
	"extra_vars":               {},
	"host_limit":               {},
	"inventory_id":             {},
	"credential_ids":           {},
	"execution_environment_id": {},
	"job_type":                 {},
	"diff_mode":                {},
	"verbosity":                {},
	"forks":                    {},
	"job_slice_count":          {},
	"timeout":                  {},
	"job_tags":                 {},
	"skip_tags":                {},
	"labels":                   {},
	"instance_group_ids":       {},
}

func buildLaunchBody(args map[string]any) (map[string]any, error) {
	for key := range args {
		if _, allowed := allowedLaunchArgs[key]; !allowed {
			return nil, fmt.Errorf("args.%s is not an allowed AWX launch field", key)
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
	if err := json.Unmarshal(page.Results[0], &user); err != nil || user.ID <= 0 {
		return errorResult("awx.current_user", fmt.Errorf("AWX current-user response is missing a numeric ID"))
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

const maxRecentJobsPageSize = 100

// runListRecentJobs handles `awx.list_recent_jobs`.
//
// Required args: template_id, inventory_id, created_by_id (positive ints) and
// created_after (RFC3339 timestamp). Optional page_size is 1..100 (default 50).
// The plugin intentionally does not filter by dispatch marker: AWX 24.6.1
// marks extra_vars non-searchable. It returns one bounded, newest-first page;
// the trusted control plane compares exact retained markers and accepted-job
// fields. `truncated=true` is a fail-closed ambiguity signal, not permission to
// select a candidate from an incomplete set.
func runListRecentJobs(cfg Config) *sdk.Result {
	templateID, templateOK := argInt(cfg.Args, "template_id")
	inventoryID, inventoryOK := argInt(cfg.Args, "inventory_id")
	createdByID, createdByOK := argInt(cfg.Args, "created_by_id")
	createdAfter, createdAfterOK := argString(cfg.Args, "created_after")
	if !templateOK || templateID <= 0 {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.template_id is required"))
	}
	if !inventoryOK || inventoryID <= 0 {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.inventory_id is required"))
	}
	if !createdByOK || createdByID <= 0 {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.created_by_id is required"))
	}
	createdAt, err := time.Parse(time.RFC3339, createdAfter)
	if !createdAfterOK || err != nil {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("args.created_after must be RFC3339"))
	}
	pageSize := 50
	if _, present := cfg.Args["page_size"]; present {
		var ok bool
		pageSize, ok = argInt(cfg.Args, "page_size")
		if !ok || pageSize <= 0 || pageSize > maxRecentJobsPageSize {
			return errorResult(
				"awx.list_recent_jobs",
				fmt.Errorf("args.page_size must be an integer between 1 and %d", maxRecentJobsPageSize),
			)
		}
	}

	query := url.Values{}
	query.Set("job_template", strconv.Itoa(templateID))
	query.Set("inventory", strconv.Itoa(inventoryID))
	query.Set("created_by", strconv.Itoa(createdByID))
	query.Set("created__gte", createdAt.UTC().Format(time.RFC3339Nano))
	query.Set("order_by", "-created")
	query.Set("page_size", strconv.Itoa(pageSize))
	path := "/api/v2/jobs/?" + query.Encode()

	resp, err := getJSON(cfg, path)
	if err != nil {
		return errorResult("awx.list_recent_jobs", err)
	}
	var page awxPage
	if err := json.Unmarshal(resp.Body, &page); err != nil {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("decode recent jobs: %w", err))
	}
	if len(page.Results) > pageSize {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("AWX returned more jobs than the requested bound"))
	}
	if page.Count < len(page.Results) {
		return errorResult("awx.list_recent_jobs", fmt.Errorf("AWX recent-job count is inconsistent"))
	}
	jobs := make([]map[string]any, 0, len(page.Results))
	for _, rawJob := range page.Results {
		job, err := sanitizeJobForReconciliation(rawJob)
		if err != nil {
			return errorResult("awx.list_recent_jobs", fmt.Errorf("decode recent job: %w", err))
		}
		if err := validateRecentJobScope(job, templateID, inventoryID, createdByID, createdAt); err != nil {
			return errorResult("awx.list_recent_jobs", err)
		}
		jobs = append(jobs, job)
	}
	payload := map[string]any{
		"verb":          "awx.list_recent_jobs",
		"ok":            true,
		"template_id":   templateID,
		"inventory_id":  inventoryID,
		"created_by_id": createdByID,
		"created_after": createdAt.UTC().Format(time.RFC3339Nano),
		"page_size":     pageSize,
		"count":         page.Count,
		"truncated":     page.Next != "" || page.Count > len(page.Results),
		"jobs":          jobs,
	}
	out, _ := json.Marshal(payload)
	return sdk.Ok(fmt.Sprintf("listed %d recent jobs", len(page.Results))).
		WithDetails(string(out)).
		WithLabel("verb", "awx.list_recent_jobs")
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

// runFetchEventsForJobs handles `awx.fetch_events_for_jobs` verb — the bulk
// pulse verb RunPulseWorker drives. Args: pairs ([]{job_id, since_id}).
//
// For each pair we GET /api/v2/jobs/{id}/job_events/?counter__gt={since_id}
// (paginated) and aggregate the result. Per-job failures don't fail the
// whole verb — the response carries per-job ok/error so the worker can
// retry the failures next tick without losing state for the others.
func runFetchEventsForJobs(cfg Config) *sdk.Result {
	pairsRaw, ok := cfg.Args["pairs"]
	if !ok {
		return errorResult("awx.fetch_events_for_jobs", fmt.Errorf("args.pairs is required"))
	}
	pairs, ok := pairsRaw.([]any)
	if !ok {
		return errorResult("awx.fetch_events_for_jobs", fmt.Errorf("args.pairs must be an array"))
	}

	jobs := make([]jobEventsResult, 0, len(pairs))
	successful := 0
	for _, p := range pairs {
		pair, ok := p.(map[string]any)
		if !ok {
			jobs = append(jobs, jobEventsResult{OK: false, Error: "pair must be an object"})
			continue
		}
		jobID, _ := argInt(pair, "job_id")
		sinceID, _ := argInt(pair, "since_id")
		if jobID <= 0 {
			jobs = append(jobs, jobEventsResult{OK: false, Error: "pair.job_id required"})
			continue
		}

		path := fmt.Sprintf(
			"/api/v2/jobs/%d/job_events/?counter__gt=%d&page_size=200&order=counter",
			jobID, sinceID,
		)
		events, total, err := listAWXPath(cfg, path)
		if err != nil {
			jobs = append(jobs, jobEventsResult{
				JobID: jobID,
				OK:    false,
				Error: sanitizeError(err),
			})
			continue
		}

		maxCounter := sinceID
		for _, ev := range events {
			var probe struct {
				Counter int `json:"counter"`
			}
			if err := json.Unmarshal(ev, &probe); err == nil && probe.Counter > maxCounter {
				maxCounter = probe.Counter
			}
		}

		jobs = append(jobs, jobEventsResult{
			JobID:      jobID,
			OK:         true,
			Events:     events,
			MaxCounter: maxCounter,
			Count:      total,
		})
		successful++
	}

	payload := map[string]any{
		"verb": "awx.fetch_events_for_jobs",
		"ok":   true,
		"jobs": jobs,
	}
	out, _ := json.Marshal(payload)

	return sdk.Ok(fmt.Sprintf("fetched events for %d/%d jobs", successful, len(jobs))).
		WithDetails(string(out)).
		WithLabel("verb", "awx.fetch_events_for_jobs")
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
		return nil, err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		if resp.Status == http.StatusUnauthorized || resp.Status == http.StatusForbidden {
			return nil, fmt.Errorf("AWX rejected the request: %d (check controller token)", resp.Status)
		}
		return nil, fmt.Errorf("AWX HTTP %d", resp.Status)
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
		return nil, err
	}
	if resp.Status == http.StatusNotFound {
		return resp, nil
	}
	if resp.Status < 200 || resp.Status >= 300 {
		if resp.Status == http.StatusUnauthorized || resp.Status == http.StatusForbidden {
			return nil, fmt.Errorf("AWX rejected the request: %d (check controller token)", resp.Status)
		}
		return nil, fmt.Errorf("AWX HTTP %d", resp.Status)
	}
	return resp, nil
}

// awxPingResponse mirrors the relevant subset of /api/v2/ping/.
type awxPingResponse struct {
	Version     string         `json:"version"`
	ActiveNode  string         `json:"active_node"`
	InstallUUID string         `json:"install_uuid"`
	HA          bool           `json:"ha"`
	Instances   []awxInstance  `json:"instances"`
	Groups      []awxInstGroup `json:"instance_groups"`
}

type awxInstance struct {
	Node      string  `json:"node"`
	NodeType  string  `json:"node_type"`
	UUID      string  `json:"uuid"`
	Version   string  `json:"version"`
	Capacity  int     `json:"capacity"`
	Heartbeat string  `json:"heartbeat"`
	Cpu       float64 `json:"cpu"`
	Memory    int64   `json:"memory"`
}

type awxInstGroup struct {
	Name      string   `json:"name"`
	Capacity  int      `json:"capacity"`
	Instances []string `json:"instances"`
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

	var ping awxPingResponse
	if err := json.Unmarshal(resp.Body, &ping); err != nil {
		return errorResult("awx.ping", fmt.Errorf("decode /api/v2/ping/: %w", err))
	}

	payload := map[string]any{
		"verb":         "awx.ping",
		"ok":           true,
		"version":      ping.Version,
		"active_node":  ping.ActiveNode,
		"install_uuid": ping.InstallUUID,
		"ha":           ping.HA,
		"instances":    ping.Instances,
		"groups":       ping.Groups,
	}
	body, _ := json.Marshal(payload)

	summary := "AWX " + nonEmpty(ping.Version, "?") + " reachable"
	if active := strings.TrimSpace(ping.ActiveNode); active != "" {
		summary += " (active: " + active + ")"
	}

	result := sdk.Ok(summary).
		WithDetails(string(body)).
		WithLabel("verb", "awx.ping")
	if ping.Version != "" {
		result.WithLabel("awx_version", ping.Version)
	}
	if ping.ActiveNode != "" {
		result.WithLabel("active_node", ping.ActiveNode)
	}
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
			return nil, 0, fmt.Errorf("decode %s: %w", next, err)
		}
		if pagesWalked == 0 {
			total = pageBody.Count
			if total > maxResults {
				return nil, total, fmt.Errorf("AWX result count %d exceeds bound %d", total, maxResults)
			}
		}
		if len(all)+len(pageBody.Results) > maxResults {
			return nil, total, fmt.Errorf("AWX results exceed bound %d", maxResults)
		}
		all = append(all, pageBody.Results...)
		pagesWalked++

		// AWX returns `next` either as null or as a path like
		// "/api/v2/inventories/?page=2". We always strip the host so
		// the same host:port the operator configured is reused.
		next = relativizeAWXPath(pageBody.Next)
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
	case strings.HasPrefix(next, "/"):
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
		return next
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

func runListInventories(cfg Config) *sdk.Result {
	results, total, err := listAWXPath(cfg, "/api/v2/inventories/?page_size=200")
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
	safeResults := make([]json.RawMessage, 0, len(results))
	for _, raw := range results {
		var group struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		}
		if err := json.Unmarshal(raw, &group); err != nil || group.ID <= 0 || strings.TrimSpace(group.Name) == "" {
			return errorResult("awx.list_inventory_groups", fmt.Errorf("AWX returned an invalid inventory group"))
		}
		safe, _ := json.Marshal(group)
		safeResults = append(safeResults, safe)
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
	return sdk.Ok(fmt.Sprintf("listed %d projects", total)).
		WithDetails(encodeListPayload("awx.list_projects", results, total, nil)).
		WithLabel("verb", "awx.list_projects")
}

func runListTemplates(cfg Config) *sdk.Result {
	results, total, err := listAWXPath(cfg, "/api/v2/job_templates/?page_size=200")
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
	if !ok {
		return errorResult("awx.fetch_template", fmt.Errorf("args.template_id is required"))
	}

	tmplResp, err := getJSON(cfg, fmt.Sprintf("/api/v2/job_templates/%d/", templateID))
	if err != nil {
		return errorResult("awx.fetch_template", err)
	}
	var tmpl json.RawMessage
	if err := json.Unmarshal(tmplResp.Body, &tmpl); err != nil {
		return errorResult("awx.fetch_template", fmt.Errorf("decode template: %w", err))
	}

	// Survey spec is on a sub-resource; AWX returns 200 with `{}` when no
	// survey is defined. A 404 is also tolerated for older AWX versions.
	var survey json.RawMessage = json.RawMessage("{}")
	if surveyResp, err := getJSON(cfg, fmt.Sprintf("/api/v2/job_templates/%d/survey_spec/", templateID)); err == nil {
		if err := json.Unmarshal(surveyResp.Body, &survey); err != nil {
			return errorResult("awx.fetch_template", fmt.Errorf("decode survey_spec: %w", err))
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
		return nil, err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		// Special-case auth: keep error short and operator-actionable.
		if resp.Status == http.StatusUnauthorized || resp.Status == http.StatusForbidden {
			return nil, fmt.Errorf("AWX rejected the request: %d (check controller token)", resp.Status)
		}
		return nil, fmt.Errorf("AWX HTTP %d", resp.Status)
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
		return nil, false, err
	}
	if resp.Status == http.StatusNotFound {
		return resp, true, nil
	}
	if resp.Status < 200 || resp.Status >= 300 {
		if resp.Status == http.StatusUnauthorized || resp.Status == http.StatusForbidden {
			return nil, false, fmt.Errorf("AWX rejected the request: %d (check controller token)", resp.Status)
		}
		return nil, false, fmt.Errorf("AWX HTTP %d", resp.Status)
	}
	return resp, false, nil
}

// sanitizeError strips any embedded URL so a sloppy upstream error doesn't
// leak the controller hostname or query strings into the operator-visible
// summary.
func sanitizeError(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	// Remove anything that looks like a scheme://host fragment.
	for _, scheme := range []string{"https://", "http://"} {
		if i := strings.Index(s, scheme); i >= 0 {
			rest := s[i+len(scheme):]
			// Stop at `/` so the path stays in the message (operator
			// diagnostic value) but host:port is redacted.
			j := strings.IndexAny(rest, "/ \t\n,;\"")
			if j < 0 {
				j = len(rest)
			}
			s = s[:i] + "<awx>" + rest[j:]
		}
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
	_, _ = json.Marshal(awxPingResponse{})
	_, _ = json.Marshal([]awxInstance{})
	_, _ = json.Marshal([]awxInstGroup{})
	_, _ = json.Marshal(map[string]any{"t": time.Time{}})
}

// InventorySyncControllerConfig describes one AWX controller in the scheduled
// `inventory_sync` entrypoint. The assignment carries resolved API tokens; core
// resolves credential-broker refs before invoking the plugin.
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
		if strings.TrimSpace(controller.APIToken) == "" {
			return fmt.Errorf("controllers[%d].api_token is required (resolved from credential broker grant)", i)
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
		Metadata: map[string]any{
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
		},
	}
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
