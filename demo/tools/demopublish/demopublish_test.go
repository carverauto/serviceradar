package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeInstance models the parts of the ServiceRadar API the publisher uses,
// with enough state to prove idempotency: approve materializes the manifest's
// alert rules disabled, as AlertRuleCatalog does.
type fakeInstance struct {
	mu          sync.Mutex
	packages    map[string]map[string]any
	blobs       map[string][]byte
	rules       map[string]map[string]any
	assignments map[string]map[string]any
	dashboards  map[string]string // manifest id@version -> hash of renderer
	enabled     map[string]bool
	mutations   []string
	lastStage   map[string]any
	nextID      int
}

func newFake() *fakeInstance {
	return &fakeInstance{
		packages: map[string]map[string]any{}, blobs: map[string][]byte{},
		rules: map[string]map[string]any{}, assignments: map[string]map[string]any{},
		dashboards: map[string]string{}, enabled: map[string]bool{},
	}
}

func (f *fakeInstance) id(prefix string) string {
	f.nextID++
	return prefix + "-" + string(rune('a'+f.nextID))
}

func (f *fakeInstance) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Method != http.MethodGet {
		f.mutations = append(f.mutations, r.Method+" "+r.URL.Path)
	}
	// The blob upload authenticates with its storage token, everything else
	// with the operator's bearer token.
	isBlob := strings.HasPrefix(r.URL.Path, "/api/plugin-packages/") && strings.HasSuffix(r.URL.Path, "/blob")
	if !isBlob && r.Header.Get("authorization") != "Bearer test-token" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}
	body, _ := io.ReadAll(r.Body)
	decode := func() map[string]any {
		var m map[string]any
		_ = json.Unmarshal(body, &m)
		return m
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/api/admin/plugin-packages":
		var out []map[string]any
		for _, p := range f.packages {
			if p["plugin_id"] == r.URL.Query().Get("plugin_id") {
				out = append(out, p)
			}
		}
		writeJSON(w, out)
	case r.Method == http.MethodPost && r.URL.Path == "/api/admin/plugin-packages":
		m := decode()
		f.lastStage = m
		id := f.id("pkg")
		f.packages[id] = map[string]any{
			"id": id, "plugin_id": m["plugin_id"], "version": m["version"],
			"content_hash": m["content_hash"], "status": "staged", "wasm_object_key": "",
			"manifest": m["manifest"],
		}
		writeJSON(w, f.packages[id])
	case r.Method == http.MethodPost && len(parts) == 5 && parts[4] == "upload-url":
		writeJSON(w, map[string]any{"upload_url": "/api/plugin-packages/" + parts[3] + "/blob", "upload_token": "blob-token-" + parts[3]})
	case r.Method == http.MethodPut && len(parts) == 4 && parts[3] == "blob":
		if r.Header.Get("x-serviceradar-plugin-token") != "blob-token-"+parts[2] {
			http.Error(w, `{"error":"bad token"}`, http.StatusUnauthorized)
			return
		}
		f.blobs[parts[2]] = body
		f.packages[parts[2]]["wasm_object_key"] = "plugins/" + parts[2]
		writeJSON(w, map[string]any{"ok": true})
	case r.Method == http.MethodPost && len(parts) == 5 && parts[4] == "approve":
		p := f.packages[parts[3]]
		p["status"] = "approved"
		manifest, _ := p["manifest"].(map[string]any)
		rules, _ := manifest["alert_rules"].([]any)
		for _, raw := range rules {
			rule := raw.(map[string]any)
			rid := f.id("rule")
			f.rules[rid] = map[string]any{"name": rule["name"], "enabled": false, "plugin_package_id": parts[3]}
		}
		writeJSON(w, p)
	case r.Method == http.MethodGet && r.URL.Path == "/api/v2/stateful-alert-rules":
		want := r.URL.Query().Get("filter[plugin_package_id]")
		var data []map[string]any
		for id, attrs := range f.rules {
			if attrs["plugin_package_id"] == want {
				data = append(data, map[string]any{"id": id, "type": "stateful-alert-rule", "attributes": attrs})
			}
		}
		writeJSON(w, map[string]any{"data": data})
	case r.Method == http.MethodPatch && len(parts) == 4 && parts[2] == "stateful-alert-rules":
		m := decode()
		attrs := m["data"].(map[string]any)["attributes"].(map[string]any)
		f.rules[parts[3]]["enabled"] = attrs["enabled"]
		writeJSON(w, map[string]any{"data": map[string]any{"id": parts[3]}})
	case r.Method == http.MethodGet && r.URL.Path == "/api/admin/plugin-assignments":
		var out []map[string]any
		for _, a := range f.assignments {
			if a["agent_uid"] == r.URL.Query().Get("agent_uid") {
				out = append(out, a)
			}
		}
		writeJSON(w, out)
	case r.Method == http.MethodPost && r.URL.Path == "/api/admin/plugin-assignments":
		m := decode()
		id := f.id("asg")
		m["id"] = id
		m["plugin_id"] = f.packages[m["plugin_package_id"].(string)]["plugin_id"]
		f.assignments[id] = m
		writeJSON(w, m)
	case r.Method == http.MethodPatch && len(parts) == 4 && parts[2] == "plugin-assignments":
		for k, v := range decode() {
			f.assignments[parts[3]][k] = v
		}
		writeJSON(w, f.assignments[parts[3]])
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/dashboard-packages":
		r.Body = io.NopCloser(bytes.NewReader(body))
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mf, mh, _ := r.FormFile("manifest")
		rf, rh, _ := r.FormFile("renderer")
		if mf == nil || rf == nil || mh.Header.Get("Content-Type") != "application/json" || rh.Header.Get("Content-Type") != "application/javascript" {
			http.Error(w, `{"error":"missing_part"}`, http.StatusBadRequest)
			return
		}
		mb, _ := io.ReadAll(mf)
		rb, _ := io.ReadAll(rf)
		var man map[string]any
		_ = json.Unmarshal(mb, &man)
		key := man["id"].(string) + "@" + man["version"].(string)
		result := "written"
		if prev, ok := f.dashboards[key]; ok {
			if prev != string(rb) {
				http.Error(w, `{"error":"version_already_published"}`, http.StatusConflict)
				return
			}
			result = "idempotent_noop"
		}
		f.dashboards[key] = string(rb)
		writeJSON(w, map[string]any{"id": "dash-" + key, "result": result})
	case r.Method == http.MethodPost && len(parts) == 5 && parts[2] == "dashboard-packages" && parts[4] == "enable":
		f.enabled[parts[3]] = true
		writeJSON(w, map[string]any{"id": parts[3]})
	default:
		http.Error(w, `{"error":"unexpected `+r.Method+" "+r.URL.Path+`"}`, http.StatusNotFound)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("content-type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (f *fakeInstance) takeMutations() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	m := f.mutations
	f.mutations = nil
	return m
}

type harness struct {
	t      *testing.T
	fake   *fakeInstance
	server *httptest.Server
	env    map[string]string
	pub    ed25519.PublicKey
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	fake := newFake()
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyFile := filepath.Join(t.TempDir(), "demo.key")
	if err := os.WriteFile(keyFile, []byte(base64.StdEncoding.EncodeToString(priv.Seed())), 0o600); err != nil {
		t.Fatal(err)
	}
	return &harness{t: t, fake: fake, server: server, pub: pub, env: map[string]string{
		"SERVICERADAR_INSTANCE":                  server.URL,
		"SERVICERADAR_TOKEN":                     "test-token",
		"PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE": keyFile,
		"PLUGIN_UPLOAD_SIGNING_KEY_ID":           "serviceradar-demo-test",
	}}
}

func (h *harness) getenv(k string) string { return h.env[k] }

// The signature tool reads its key from the process environment.
func (h *harness) exportSigningEnv() {
	for _, k := range []string{"PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE", "PLUGIN_UPLOAD_SIGNING_KEY_ID"} {
		h.t.Setenv(k, h.env[k])
	}
}

func (h *harness) run(extra ...string) (string, error) {
	var out bytes.Buffer
	args := append([]string{"--bundle", bundlePath(h.t), "--signature-tool", signatureTool(h.t)}, extra...)
	err := run(args, h.getenv, &out, h.server.Client())
	return out.String(), err
}

func bundlePath(t *testing.T) string   { return runfile(t, "DEMO_BUNDLE") }
func signatureTool(t *testing.T) string { return runfile(t, "SIGNATURE_TOOL") }

func runfile(t *testing.T, env string) string {
	t.Helper()
	p := os.Getenv(env)
	if p == "" {
		t.Fatalf("%s not set (run under bazel test)", env)
	}
	// rootpath is relative to the runfiles root; rules_go runs tests from the
	// package directory, so anchor it explicitly.
	if srcdir := os.Getenv("TEST_SRCDIR"); srcdir != "" && !filepath.IsAbs(p) {
		return filepath.Join(srcdir, os.Getenv("TEST_WORKSPACE"), p)
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

func TestPublishIsCompleteAndSigned(t *testing.T) {
	h := newHarness(t)
	h.exportSigningEnv()
	params := filepath.Join(t.TempDir(), "params.json")
	if err := os.WriteFile(params, []byte(`{"interval_seconds":30}`), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := h.run("--agent-uid", "agent-demo-1", "--interval", "30", "--params-file", params)
	if err != nil {
		t.Fatalf("publish: %v\n%s", err, out)
	}

	f := h.fake
	if len(f.packages) != 1 {
		t.Fatalf("packages = %d", len(f.packages))
	}
	var pkg map[string]any
	for _, p := range f.packages {
		pkg = p
	}
	if pkg["status"] != "approved" || pkg["plugin_id"] != "demo-hello-sim" {
		t.Fatalf("package = %+v", pkg)
	}
	if len(f.blobs[pkg["id"].(string)]) == 0 {
		t.Fatal("wasm was not uploaded")
	}
	for _, r := range f.rules {
		if r["enabled"] != true {
			t.Fatalf("alert rule left disabled: %+v", r)
		}
	}
	if len(f.rules) != 1 {
		t.Fatalf("rules = %d, want the manifest's one rule", len(f.rules))
	}
	if len(f.assignments) != 1 {
		t.Fatalf("assignments = %d", len(f.assignments))
	}
	for _, a := range f.assignments {
		if a["agent_uid"] != "agent-demo-1" || a["enabled"] != true || a["interval_seconds"] != float64(30) {
			t.Fatalf("assignment = %+v", a)
		}
	}

	// The staged signature must verify against the bundle with the public key,
	// using the same tool the release pipeline uses.
	sig, ok := f.lastStage["signature"].(map[string]any)
	if !ok || sig["key_id"] != "serviceradar-demo-test" {
		t.Fatalf("staged signature = %+v", f.lastStage["signature"])
	}
	if sig["content_hash"] != f.lastStage["content_hash"] {
		t.Fatalf("signature content hash %v != staged %v", sig["content_hash"], f.lastStage["content_hash"])
	}
	sigFile := filepath.Join(t.TempDir(), "sig.json")
	data, _ := json.Marshal(sig)
	if err := os.WriteFile(sigFile, data, 0o600); err != nil {
		t.Fatal(err)
	}
	verify := exec.Command(signatureTool(t), "verify", "--bundle", bundlePath(t), "--signature", sigFile)
	verify.Env = append(os.Environ(), "PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY="+base64.StdEncoding.EncodeToString(h.pub))
	if msg, err := verify.CombinedOutput(); err != nil {
		t.Fatalf("staged signature does not verify: %v: %s", err, msg)
	}
	// A different key must not verify it (the check above can fail).
	otherPub, _, _ := ed25519.GenerateKey(rand.Reader)
	reject := exec.Command(signatureTool(t), "verify", "--bundle", bundlePath(t), "--signature", sigFile)
	reject.Env = append(os.Environ(), "PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY="+base64.StdEncoding.EncodeToString(otherPub))
	if err := reject.Run(); err == nil {
		t.Fatal("signature verified under an unrelated public key")
	}
}

func TestRepublishChangesNothing(t *testing.T) {
	h := newHarness(t)
	h.exportSigningEnv()
	dash := dashboardDir(t, "renderer v1")
	args := []string{"--agent-uid", "agent-demo-1", "--dashboard-dir", dash, "--dashboard-route", "hello-sim"}
	if out, err := h.run(args...); err != nil {
		t.Fatalf("first publish: %v\n%s", err, out)
	}
	first := h.fake.takeMutations()
	if len(first) == 0 {
		t.Fatal("first publish made no changes")
	}
	out, err := h.run(args...)
	if err != nil {
		t.Fatalf("second publish: %v\n%s", err, out)
	}
	// Re-running may re-send the dashboard (the server answers idempotent_noop)
	// and re-enable it; nothing about the plugin, rules or assignment changes.
	for _, m := range h.fake.takeMutations() {
		if !strings.Contains(m, "/dashboard-packages") {
			t.Fatalf("second publish mutated %s", m)
		}
	}
	if !strings.Contains(out, "already approved") || !strings.Contains(out, "already enabled") ||
		!strings.Contains(out, "already current") || !strings.Contains(out, "idempotent_noop") {
		t.Fatalf("second publish output does not report no-ops:\n%s", out)
	}
}

func TestChangedAssignmentParamsAreUpdated(t *testing.T) {
	h := newHarness(t)
	h.exportSigningEnv()
	if _, err := h.run("--agent-uid", "agent-demo-1", "--interval", "60"); err != nil {
		t.Fatal(err)
	}
	h.fake.takeMutations()
	if _, err := h.run("--agent-uid", "agent-demo-1", "--interval", "30"); err != nil {
		t.Fatal(err)
	}
	m := h.fake.takeMutations()
	if len(m) != 1 || !strings.HasPrefix(m[0], "PATCH /api/admin/plugin-assignments/") {
		t.Fatalf("mutations = %v, want one assignment PATCH", m)
	}
}

func TestSameVersionDifferentContentIsRefused(t *testing.T) {
	h := newHarness(t)
	h.exportSigningEnv()
	h.fake.packages["pkg-old"] = map[string]any{
		"id": "pkg-old", "plugin_id": "demo-hello-sim", "version": "0.1.0",
		"content_hash": "sha256:0000", "status": "approved", "wasm_object_key": "x",
	}
	out, err := h.run()
	if err == nil || !strings.Contains(err.Error(), "bump version") {
		t.Fatalf("err = %v\n%s", err, out)
	}
	if m := h.fake.takeMutations(); len(m) != 0 {
		t.Fatalf("refused publish still mutated: %v", m)
	}
}

func TestMissingSigningKeyStopsBeforeAnyRequest(t *testing.T) {
	h := newHarness(t)
	delete(h.env, "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE")
	_, err := h.run()
	if err == nil || !strings.Contains(err.Error(), "no upload signing key") {
		t.Fatalf("err = %v", err)
	}
	if m := h.fake.takeMutations(); len(m) != 0 {
		t.Fatalf("mutations without a key: %v", m)
	}
}

func TestMissingTokenIsRejected(t *testing.T) {
	h := newHarness(t)
	delete(h.env, "SERVICERADAR_TOKEN")
	if _, err := h.run(); err == nil || !strings.Contains(err.Error(), "SERVICERADAR_TOKEN") {
		t.Fatalf("err = %v", err)
	}
}

func dashboardDir(t *testing.T, renderer string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte(`{"id":"com.example.hello-sim","version":"0.1.0"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "renderer.js"), []byte(renderer), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}
