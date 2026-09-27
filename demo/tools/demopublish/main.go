// Command demopublish publishes a showcase demo to a ServiceRadar instance:
// it signs the plugin bundle with the demo-only upload key, stages, uploads and
// approves the plugin package, enables the alert rules the manifest proposes,
// assigns the plugin to an agent, and optionally publishes and enables the
// demo's dashboard package. Every step checks current state first, so running
// it again with unchanged artifacts changes nothing.
//
// It is run through `bazel run` (see //demo:defs.bzl demo_publish). Secrets
// come from the client environment at run time and never from build inputs:
//
//	SERVICERADAR_INSTANCE   instance base URL (or --instance)
//	SERVICERADAR_TOKEN      operator bearer token (plugin publish/approve,
//	                        assignments, alert rules, dashboard publish)
//	PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY[_FILE], PLUGIN_UPLOAD_SIGNING_KEY_ID
//	                        read by //build/wasm_plugins:upload_signature_tool
//	SERVICERADAR_CA_FILE    optional PEM bundle for a private-CA instance
package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type config struct {
	instance         string
	token            string
	bundle           string
	signatureTool    string
	agentUID         string
	paramsFile       string
	interval         int
	dashboardDir     string
	dashboardRoute   string
	enableAlertRules bool
	allowUnsigned    bool
	dryRun           bool
	caFile           string
}

func main() {
	if err := run(os.Args[1:], os.Getenv, os.Stdout, nil); err != nil {
		fmt.Fprintf(os.Stderr, "demopublish: %v\n", err)
		os.Exit(1)
	}
}

// run is main with its dependencies injectable for tests.
func run(args []string, getenv func(string) string, out io.Writer, client *http.Client) error {
	cfg, err := parseConfig(args, getenv)
	if err != nil {
		return err
	}
	bundle, err := readBundle(cfg.bundle)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "plugin   %s@%s (sha256 %s)\n", bundle.id, bundle.version, bundle.contentHash[:12])

	var signature map[string]any
	if hasSigningKey(getenv) {
		signature, err = sign(cfg, getenv)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "signed   key %v\n", signature["key_id"])
	} else if !cfg.allowUnsigned {
		return errors.New("no upload signing key: set PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE and PLUGIN_UPLOAD_SIGNING_KEY_ID, or pass --allow-unsigned")
	}

	var dashboard *dashboardFiles
	if cfg.dashboardDir != "" {
		if dashboard, err = readDashboard(cfg.dashboardDir); err != nil {
			return err
		}
	}
	var params map[string]any
	if cfg.paramsFile != "" {
		if params, err = readParams(cfg.paramsFile); err != nil {
			return err
		}
	}
	if cfg.dryRun {
		fmt.Fprintf(out, "dry run  would publish to %s (agent %q, dashboard %v)\n", cfg.instance, cfg.agentUID, dashboard != nil)
		return nil
	}

	if client == nil {
		if client, err = httpClient(cfg.caFile); err != nil {
			return err
		}
	}
	p := &publisher{base: strings.TrimRight(cfg.instance, "/"), token: cfg.token, http: client, out: out}

	pkgID, err := p.ensurePackage(bundle, signature)
	if err != nil {
		return err
	}
	if cfg.enableAlertRules && len(bundle.alertRules) > 0 {
		if err := p.enableAlertRules(pkgID, bundle.alertRules); err != nil {
			return err
		}
	}
	if cfg.agentUID != "" {
		if err := p.ensureAssignment(bundle.id, pkgID, cfg.agentUID, cfg.interval, params); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(out, "assign   skipped (no --agent-uid)")
	}
	if dashboard != nil {
		if err := p.publishDashboard(dashboard, cfg.dashboardRoute); err != nil {
			return err
		}
	}
	fmt.Fprintln(out, "done")
	return nil
}

func parseConfig(args []string, getenv func(string) string) (config, error) {
	fs := flag.NewFlagSet("demopublish", flag.ContinueOnError)
	cfg := config{}
	fs.StringVar(&cfg.instance, "instance", getenv("SERVICERADAR_INSTANCE"), "instance base URL")
	fs.StringVar(&cfg.bundle, "bundle", "", "plugin bundle zip")
	fs.StringVar(&cfg.signatureTool, "signature-tool", "", "upload_signature_tool binary")
	fs.StringVar(&cfg.agentUID, "agent-uid", getenv("DEMO_AGENT_UID"), "agent to assign the plugin to")
	fs.StringVar(&cfg.paramsFile, "params-file", "", "JSON file with the assignment params")
	fs.IntVar(&cfg.interval, "interval", 60, "assignment interval in seconds")
	fs.StringVar(&cfg.dashboardDir, "dashboard-dir", "", "built dashboard (manifest.json + renderer.js)")
	fs.StringVar(&cfg.dashboardRoute, "dashboard-route", "", "route slug to bind the dashboard to")
	fs.BoolVar(&cfg.enableAlertRules, "enable-alert-rules", true, "enable the alert rules the manifest proposes")
	fs.BoolVar(&cfg.allowUnsigned, "allow-unsigned", false, "publish without an upload signature")
	fs.BoolVar(&cfg.dryRun, "dry-run", false, "validate inputs and stop before contacting the instance")
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}
	cfg.token = getenv("SERVICERADAR_TOKEN")
	cfg.caFile = userPath(getenv("SERVICERADAR_CA_FILE"), getenv)
	cfg.paramsFile = userPath(cfg.paramsFile, getenv)
	cfg.dashboardDir = userPath(cfg.dashboardDir, getenv)

	switch {
	case cfg.bundle == "":
		return cfg, errors.New("--bundle is required")
	case cfg.instance == "" && !cfg.dryRun:
		return cfg, errors.New("--instance or SERVICERADAR_INSTANCE is required")
	case cfg.token == "" && !cfg.dryRun:
		return cfg, errors.New("SERVICERADAR_TOKEN is required")
	case cfg.interval <= 0:
		return cfg, errors.New("--interval must be positive")
	}
	if cfg.instance != "" {
		u, err := url.Parse(cfg.instance)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
			return cfg, fmt.Errorf("--instance must be an absolute http(s) URL: %q", cfg.instance)
		}
	}
	return cfg, nil
}

// userPath resolves a path the operator typed. Under `bazel run` the working
// directory is the runfiles tree, so relative paths are taken from
// BUILD_WORKING_DIRECTORY unless they exist where we are (runfiles paths
// passed by the build rule itself).
func userPath(p string, getenv func(string) string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	if _, err := os.Stat(p); err == nil {
		return p
	}
	if wd := getenv("BUILD_WORKING_DIRECTORY"); wd != "" {
		return filepath.Join(wd, p)
	}
	return p
}

type bundleFiles struct {
	id, name, version string
	manifest          map[string]any
	configSchema      map[string]any
	wasm              []byte
	contentHash       string
	alertRules        []string
}

func readBundle(path string) (*bundleFiles, error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, fmt.Errorf("open bundle: %w", err)
	}
	defer zr.Close()
	files := map[string][]byte{}
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, err
		}
		files[f.Name] = data
	}
	b := &bundleFiles{wasm: files["plugin.wasm"]}
	if len(b.wasm) == 0 {
		return nil, errors.New("bundle has no plugin.wasm")
	}
	if err := yaml.Unmarshal(files["plugin.yaml"], &b.manifest); err != nil || b.manifest == nil {
		return nil, fmt.Errorf("bundle plugin.yaml: %v", err)
	}
	if raw, ok := files["config.schema.json"]; ok {
		if err := json.Unmarshal(raw, &b.configSchema); err != nil {
			return nil, fmt.Errorf("bundle config.schema.json: %w", err)
		}
	}
	b.id, _ = b.manifest["id"].(string)
	b.name, _ = b.manifest["name"].(string)
	b.version, _ = b.manifest["version"].(string)
	if b.id == "" || b.version == "" {
		return nil, errors.New("plugin.yaml needs id and version")
	}
	if rules, ok := b.manifest["alert_rules"].([]any); ok {
		for _, r := range rules {
			if m, ok := r.(map[string]any); ok {
				if name, ok := m["name"].(string); ok {
					b.alertRules = append(b.alertRules, name)
				}
			}
		}
	}
	sum := sha256.Sum256(b.wasm)
	b.contentHash = hex.EncodeToString(sum[:])
	return b, nil
}

func hasSigningKey(getenv func(string) string) bool {
	for _, k := range []string{"PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY", "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE", "PLUGIN_UPLOAD_SIGNING_TRANSIT_KEY"} {
		if strings.TrimSpace(getenv(k)) != "" {
			return true
		}
	}
	return false
}

// sign runs the first-party upload signature tool against the bundle. The key
// reaches it through the environment only.
func sign(cfg config, getenv func(string) string) (map[string]any, error) {
	if cfg.signatureTool == "" {
		return nil, errors.New("--signature-tool is required to sign")
	}
	dir, err := os.MkdirTemp("", "demopublish-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	sigPath := filepath.Join(dir, "upload-signature.json")

	cmd := exec.Command(cfg.signatureTool, "sign", "--bundle", cfg.bundle, "--out", sigPath)
	cmd.Env = os.Environ()
	if keyFile := getenv("PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE"); keyFile != "" {
		cmd.Env = append(cmd.Env, "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE="+userPath(keyFile, getenv))
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("sign bundle: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	data, err := os.ReadFile(sigPath)
	if err != nil {
		return nil, err
	}
	var sig map[string]any
	if err := json.Unmarshal(data, &sig); err != nil {
		return nil, fmt.Errorf("signature output: %w", err)
	}
	return sig, nil
}

type dashboardFiles struct {
	manifest []byte
	renderer []byte
	id       string
	version  string
}

func readDashboard(dir string) (*dashboardFiles, error) {
	manifest, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("dashboard: %w", err)
	}
	renderer, err := os.ReadFile(filepath.Join(dir, "renderer.js"))
	if err != nil {
		return nil, fmt.Errorf("dashboard: %w", err)
	}
	var m struct {
		ID      string `json:"id"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, fmt.Errorf("dashboard manifest.json: %w", err)
	}
	return &dashboardFiles{manifest: manifest, renderer: renderer, id: m.ID, version: m.Version}, nil
}

func readParams(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var params map[string]any
	if err := json.Unmarshal(data, &params); err != nil {
		return nil, fmt.Errorf("--params-file: %w", err)
	}
	return params, nil
}

func httpClient(caFile string) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("SERVICERADAR_CA_FILE %s holds no certificates", caFile)
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Transport: transport, Timeout: 2 * time.Minute}, nil
}

type publisher struct {
	base  string
	token string
	http  *http.Client
	out   io.Writer
}

type remotePackage struct {
	ID            string `json:"id"`
	PluginID      string `json:"plugin_id"`
	Version       string `json:"version"`
	ContentHash   string `json:"content_hash"`
	Status        string `json:"status"`
	WasmObjectKey string `json:"wasm_object_key"`
}

// ensurePackage leaves the bundle's version approved on the instance and
// returns its package id.
func (p *publisher) ensurePackage(b *bundleFiles, signature map[string]any) (string, error) {
	var existing []remotePackage
	if err := p.getJSON("/api/admin/plugin-packages?plugin_id="+url.QueryEscape(b.id)+"&limit=500", &existing); err != nil {
		return "", err
	}
	var pkg *remotePackage
	for i := range existing {
		if existing[i].PluginID == b.id && existing[i].Version == b.version {
			pkg = &existing[i]
			break
		}
	}
	if pkg != nil && normalizeHash(pkg.ContentHash) != normalizeHash(b.contentHash) {
		return "", fmt.Errorf("%s@%s is already on the instance with different content (%s); bump version in plugin.yaml", b.id, b.version, shortHash(pkg.ContentHash))
	}
	if pkg != nil && (pkg.Status == "denied" || pkg.Status == "revoked") {
		return "", fmt.Errorf("%s@%s is %s on the instance; restage or bump the version", b.id, b.version, pkg.Status)
	}

	if pkg == nil {
		body := map[string]any{
			"plugin_id":     b.id,
			"name":          b.name,
			"version":       b.version,
			"description":   b.manifest["description"],
			"entrypoint":    b.manifest["entrypoint"],
			"runtime":       b.manifest["runtime"],
			"outputs":       b.manifest["outputs"],
			"manifest":      b.manifest,
			"content_hash":  b.contentHash,
			"source_type":   "upload",
			"config_schema": b.configSchema,
		}
		if signature != nil {
			body["signature"] = signature
		}
		var created remotePackage
		if err := p.sendJSON(http.MethodPost, "/api/admin/plugin-packages", body, &created); err != nil {
			return "", fmt.Errorf("stage: %w", err)
		}
		if created.ID == "" {
			return "", errors.New("stage returned no package id")
		}
		pkg = &created
		fmt.Fprintf(p.out, "staged   %s\n", pkg.ID)
	}

	if pkg.WasmObjectKey == "" {
		if err := p.uploadWasm(pkg.ID, b.wasm); err != nil {
			return "", err
		}
		fmt.Fprintf(p.out, "uploaded %d bytes\n", len(b.wasm))
	}

	if pkg.Status != "approved" {
		body := map[string]any{
			"approved_capabilities": b.manifest["capabilities"],
			"approved_permissions":  b.manifest["permissions"],
			"approved_resources":    b.manifest["resources"],
		}
		if err := p.sendJSON(http.MethodPost, "/api/admin/plugin-packages/"+url.PathEscape(pkg.ID)+"/approve", body, nil); err != nil {
			return "", fmt.Errorf("approve: %w", err)
		}
		fmt.Fprintf(p.out, "approved %s\n", pkg.ID)
	} else {
		fmt.Fprintf(p.out, "package  %s already approved\n", pkg.ID)
	}
	return pkg.ID, nil
}

func (p *publisher) uploadWasm(pkgID string, wasm []byte) error {
	var token struct {
		UploadURL   string `json:"upload_url"`
		UploadToken string `json:"upload_token"`
	}
	if err := p.sendJSON(http.MethodPost, "/api/admin/plugin-packages/"+url.PathEscape(pkgID)+"/upload-url", map[string]any{}, &token); err != nil {
		return fmt.Errorf("upload-url: %w", err)
	}
	if token.UploadToken == "" {
		return errors.New("upload-url returned no upload_token")
	}
	target := token.UploadURL
	if target == "" {
		target = "/api/plugin-packages/" + url.PathEscape(pkgID) + "/blob"
	}
	if strings.HasPrefix(target, "/") {
		target = p.base + target
	}
	req, err := http.NewRequest(http.MethodPut, target, bytes.NewReader(wasm))
	if err != nil {
		return err
	}
	// The blob route reads this header and ignores a bearer token.
	req.Header.Set("x-serviceradar-plugin-token", token.UploadToken)
	req.Header.Set("content-type", "application/wasm")
	req.Header.Set("accept", "application/json")
	return p.do(req, nil, "upload")
}

type jsonAPIRule struct {
	ID         string `json:"id"`
	Attributes struct {
		Name            string `json:"name"`
		Enabled         bool   `json:"enabled"`
		PluginPackageID string `json:"plugin_package_id"`
	} `json:"attributes"`
}

// enableAlertRules turns on the rules the package proposed. The platform
// creates them disabled on approve; enabling them here is the operator's
// decision, made by running this target.
func (p *publisher) enableAlertRules(pkgID string, names []string) error {
	var doc struct {
		Data []jsonAPIRule `json:"data"`
	}
	path := "/api/v2/stateful-alert-rules?filter%5Bplugin_package_id%5D=" + url.QueryEscape(pkgID)
	if err := p.getJSONAPI(path, &doc); err != nil {
		return fmt.Errorf("list alert rules: %w", err)
	}
	byName := map[string]jsonAPIRule{}
	for _, r := range doc.Data {
		if r.Attributes.PluginPackageID == pkgID {
			byName[r.Attributes.Name] = r
		}
	}
	for _, name := range names {
		rule, ok := byName[name]
		if !ok {
			return fmt.Errorf("alert rule %q was not created for package %s (the platform syncs manifest rules on approve)", name, pkgID)
		}
		if rule.Attributes.Enabled {
			fmt.Fprintf(p.out, "rule     %s already enabled\n", name)
			continue
		}
		patch := map[string]any{"data": map[string]any{
			"type": "stateful-alert-rule", "id": rule.ID,
			"attributes": map[string]any{"enabled": true},
		}}
		if err := p.sendJSONAPI(http.MethodPatch, "/api/v2/stateful-alert-rules/"+url.PathEscape(rule.ID), patch); err != nil {
			return fmt.Errorf("enable alert rule %s: %w", name, err)
		}
		fmt.Fprintf(p.out, "rule     %s enabled\n", name)
	}
	return nil
}

type remoteAssignment struct {
	ID              string         `json:"id"`
	AgentUID        string         `json:"agent_uid"`
	PluginID        string         `json:"plugin_id"`
	PluginPackageID string         `json:"plugin_package_id"`
	Enabled         bool           `json:"enabled"`
	IntervalSeconds int            `json:"interval_seconds"`
	Params          map[string]any `json:"params"`
}

func (p *publisher) ensureAssignment(pluginID, pkgID, agentUID string, interval int, params map[string]any) error {
	if params == nil {
		params = map[string]any{}
	}
	var existing []remoteAssignment
	q := "/api/admin/plugin-assignments?agent_uid=" + url.QueryEscape(agentUID) + "&plugin_id=" + url.QueryEscape(pluginID) + "&limit=500"
	if err := p.getJSON(q, &existing); err != nil {
		return fmt.Errorf("list assignments: %w", err)
	}
	desired := map[string]any{
		"plugin_package_id": pkgID,
		"enabled":           true,
		"interval_seconds":  interval,
		"params":            params,
	}
	for _, a := range existing {
		if a.AgentUID != agentUID || a.PluginID != pluginID {
			continue
		}
		if a.PluginPackageID == pkgID && a.Enabled && a.IntervalSeconds == interval && sameJSON(a.Params, params) {
			fmt.Fprintf(p.out, "assign   %s already current on %s\n", a.ID, agentUID)
			return nil
		}
		if err := p.sendJSON(http.MethodPatch, "/api/admin/plugin-assignments/"+url.PathEscape(a.ID), desired, nil); err != nil {
			return fmt.Errorf("update assignment: %w", err)
		}
		fmt.Fprintf(p.out, "assign   %s updated on %s\n", a.ID, agentUID)
		return nil
	}
	desired["agent_uid"] = agentUID
	var created remoteAssignment
	if err := p.sendJSON(http.MethodPost, "/api/admin/plugin-assignments", desired, &created); err != nil {
		return fmt.Errorf("create assignment: %w", err)
	}
	fmt.Fprintf(p.out, "assign   %s created on %s\n", created.ID, agentUID)
	return nil
}

func (p *publisher) publishDashboard(d *dashboardFiles, route string) error {
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	if err := writePart(mw, "manifest", "manifest.json", "application/json", d.manifest); err != nil {
		return err
	}
	if err := writePart(mw, "renderer", "renderer.js", "application/javascript", d.renderer); err != nil {
		return err
	}
	if route != "" {
		if err := mw.WriteField("route", route); err != nil {
			return err
		}
	}
	if err := mw.Close(); err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, p.base+"/api/v1/dashboard-packages", &body)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", mw.FormDataContentType())
	req.Header.Set("accept", "application/json")
	var result struct {
		ID     string `json:"id"`
		Result string `json:"result"`
	}
	if err := p.do(req, &result, "dashboard publish"); err != nil {
		return err
	}
	fmt.Fprintf(p.out, "dashboard %s@%s %s\n", d.id, d.version, result.Result)
	enable := map[string]any{}
	if route != "" {
		enable["route"] = route
	}
	if err := p.sendJSON(http.MethodPost, "/api/v1/dashboard-packages/"+url.PathEscape(result.ID)+"/enable", enable, nil); err != nil {
		return fmt.Errorf("dashboard enable: %w", err)
	}
	fmt.Fprintf(p.out, "dashboard enabled\n")
	return nil
}

func writePart(mw *multipart.Writer, field, filename, contentType string, data []byte) error {
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name=%q; filename=%q`, field, filename))
	h.Set("Content-Type", contentType)
	w, err := mw.CreatePart(h)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

func (p *publisher) getJSON(path string, out any) error {
	req, err := http.NewRequest(http.MethodGet, p.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("accept", "application/json")
	return p.do(req, out, "GET "+strings.SplitN(path, "?", 2)[0])
}

func (p *publisher) sendJSON(method, path string, body, out any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(method, p.base+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("accept", "application/json")
	return p.do(req, out, method+" "+path)
}

func (p *publisher) getJSONAPI(path string, out any) error {
	req, err := http.NewRequest(http.MethodGet, p.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("accept", "application/vnd.api+json")
	return p.do(req, out, "GET "+strings.SplitN(path, "?", 2)[0])
}

func (p *publisher) sendJSONAPI(method, path string, body any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(method, p.base+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/vnd.api+json")
	req.Header.Set("accept", "application/vnd.api+json")
	return p.do(req, nil, method+" "+path)
}

func (p *publisher) do(req *http.Request, out any, what string) error {
	if req.Header.Get("x-serviceradar-plugin-token") == "" {
		req.Header.Set("authorization", "Bearer "+p.token)
	}
	resp, err := p.http.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		snippet := strings.TrimSpace(string(data))
		if len(snippet) > 400 {
			snippet = snippet[:400]
		}
		return fmt.Errorf("%s: HTTP %d: %s", what, resp.StatusCode, snippet)
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("%s: decode response: %w", what, err)
	}
	return nil
}

func sameJSON(a, b map[string]any) bool {
	aj, errA := json.Marshal(a)
	bj, errB := json.Marshal(b)
	if errA != nil || errB != nil {
		return false
	}
	var an, bn any
	_ = json.Unmarshal(aj, &an)
	_ = json.Unmarshal(bj, &bn)
	return reflect.DeepEqual(an, bn)
}

func normalizeHash(h string) string {
	return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(h)), "sha256:")
}

func shortHash(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}
