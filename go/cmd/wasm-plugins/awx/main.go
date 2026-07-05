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
	"encoding/json"
	"fmt"
	"net/http"
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
	case "awx.list_projects":
		return runListProjects(cfg)
	case "awx.list_templates":
		return runListTemplates(cfg)
	case "awx.fetch_template":
		return runFetchTemplate(cfg)
	case "awx.launch_job":
		return runLaunchJob(cfg)
	case "awx.fetch_job":
		return runFetchJob(cfg)
	case "awx.cancel_job":
		return runCancelJob(cfg)
	case "awx.fetch_events_for_jobs":
		return runFetchEventsForJobs(cfg)
	default:
		return sdk.Critical(fmt.Sprintf("unknown verb %q", verb))
	}
}

func notImplemented(verb string) *sdk.Result {
	return sdk.Critical(fmt.Sprintf("verb %q not yet implemented in this plugin build", verb))
}

// runLaunchJob handles `awx.launch_job` verb.
//
// Required args: template_id (int).
// Optional args: extra_vars (map), host_limit (string), inventory_id (int).
//
// AWX accepts a `limit:` parameter that scopes the run to a comma-joined list
// of host names — this is what the Device Actions modal sends when running
// against a specific selection of devices.
func runLaunchJob(cfg Config) *sdk.Result {
	templateID, ok := argInt(cfg.Args, "template_id")
	if !ok {
		return errorResult("awx.launch_job", fmt.Errorf("args.template_id is required"))
	}

	reqBody := map[string]any{}
	if extraVars, ok := argMap(cfg.Args, "extra_vars"); ok && len(extraVars) > 0 {
		reqBody["extra_vars"] = extraVars
	}
	if limit, ok := argString(cfg.Args, "host_limit"); ok && limit != "" {
		reqBody["limit"] = limit
	}
	if inv, ok := argInt(cfg.Args, "inventory_id"); ok && inv > 0 {
		reqBody["inventory"] = inv
	}

	resp, err := postJSON(cfg, fmt.Sprintf("/api/v2/job_templates/%d/launch/", templateID), reqBody)
	if err != nil {
		return errorResult("awx.launch_job", err)
	}

	var job json.RawMessage
	if err := json.Unmarshal(resp.Body, &job); err != nil {
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

// runFetchJob handles `awx.fetch_job` verb. Required arg: job_id.
//
// RunPulseWorker uses this to detect terminal-status transitions when no
// new task events have fired in a tick (the watermark hasn't moved but the
// job may have finished).
func runFetchJob(cfg Config) *sdk.Result {
	jobID, ok := argInt(cfg.Args, "job_id")
	if !ok {
		return errorResult("awx.fetch_job", fmt.Errorf("args.job_id is required"))
	}
	resp, err := getJSON(cfg, fmt.Sprintf("/api/v2/jobs/%d/", jobID))
	if err != nil {
		return errorResult("awx.fetch_job", err)
	}
	var job json.RawMessage
	if err := json.Unmarshal(resp.Body, &job); err != nil {
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

// maxPaginationPages caps how far we walk a paginated endpoint per verb
// invocation. With AWX's default page_size of 200 this allows up to 10k
// records, which exceeds the practical inventory sizes we expect; if it
// ever becomes a problem we'll switch to an explicit since-cursor verb.
const maxPaginationPages = 50

// listAWXPath walks /api/v2/<resource>/?... following the `next` link until
// it's null or we hit `maxPaginationPages`. Returns the aggregated raw
// results and the controller-reported total count.
func listAWXPath(cfg Config, path string) ([]json.RawMessage, int, error) {
	var (
		all   []json.RawMessage
		total int
		next  = path
	)
	for page := 0; page < maxPaginationPages && next != ""; page++ {
		resp, err := getJSON(cfg, next)
		if err != nil {
			return nil, 0, err
		}
		var pageBody awxPage
		if err := json.Unmarshal(resp.Body, &pageBody); err != nil {
			return nil, 0, fmt.Errorf("decode %s: %w", next, err)
		}
		if page == 0 {
			total = pageBody.Count
		}
		all = append(all, pageBody.Results...)

		// AWX returns `next` either as null or as a path like
		// "/api/v2/inventories/?page=2". We always strip the host so
		// the same host:port the operator configured is reused.
		next = relativizeAWXPath(pageBody.Next)
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
	if !ok {
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
		return int(n), true
	case int:
		return n, true
	case int64:
		return int(n), true
	}
	return 0, false
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
	discovery := sdk.NewDeviceDiscovery("awx")
	discovery.ObservedAt = now.Format(time.RFC3339Nano)
	discovery.CollectionID = "awx-" + cfg.ControllerID + "-" + now.Format("20060102T150405Z")
	if discovery.Metadata == nil {
		discovery.Metadata = map[string]any{}
	}
	discovery.Metadata["controller_id"] = cfg.ControllerID
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
	for _, row := range invRows {
		var inv awxInventoryRow
		if err := json.Unmarshal(row, &inv); err != nil {
			// Skip malformed rows but keep going; one bad row shouldn't
			// fail the whole sync.
			continue
		}
		totalInventories++

		hostsPath := fmt.Sprintf("/api/v2/inventories/%d/hosts/?page_size=200", inv.ID)
		hostRows, _, err := listAWXPath(cmdCfg, hostsPath)
		if err != nil {
			// Per-inventory failure: continue with what we have, but
			// stash a metadata note so DIRE can see partial coverage.
			discovery.Metadata["error_inventory_"+strconv.Itoa(inv.ID)] = sanitizeError(err)
			continue
		}

		for _, hostRow := range hostRows {
			var host awxHostRow
			if err := json.Unmarshal(hostRow, &host); err != nil {
				continue
			}
			discovery.AddDevice(buildDiscoveredHost(cfg, inv, host))
			totalHosts++
		}
	}
	discovery.Metadata["inventory_count"] = totalInventories

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
	ip := ""
	if v := extractAnsibleHostFromVariables(host.Variables); v != "" {
		if isProbablyIP(v) {
			ip = v
		} else if hostname == "" {
			hostname = v
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
				"variables":       host.Variables,
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
