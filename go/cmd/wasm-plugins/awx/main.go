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
	case
		"awx.launch_job",
		"awx.fetch_job",
		"awx.cancel_job",
		"awx.fetch_events_for_jobs":
		return notImplemented(verb)
	default:
		return sdk.Critical(fmt.Sprintf("unknown verb %q", verb))
	}
}

func notImplemented(verb string) *sdk.Result {
	return sdk.Critical(fmt.Sprintf("verb %q not yet implemented in this plugin build", verb))
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

// main is required by TinyGo's wasi target even though run_check is the
// real export. Mirrors proxmox/main.go.
func main() {}
