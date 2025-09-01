package api

import (
    "bytes"
    "context"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"

    "github.com/gorilla/mux"
    "github.com/carverauto/serviceradar/pkg/models"
)

func newTestAPIServer() *APIServer {
    s := NewAPIServer(models.CORSConfig{})
    // Inject a no-op kvPutFn by default
    s.kvPutFn = func(_ context.Context, _ string, _ []byte, _ int64) error { return nil }
    return s
}

func TestHandleUpdateConfig_Sweep_DefaultKey(t *testing.T) {
    s := newTestAPIServer()

    var gotKey string
    var gotBody []byte
    s.kvPutFn = func(_ context.Context, key string, value []byte, _ int64) error {
        gotKey = key
        gotBody = value
        return nil
    }

    body := map[string]any{"networks": []string{"10.0.0.0/24"}}
    buf, _ := json.Marshal(body)

    req := httptest.NewRequest(http.MethodPut, "/api/admin/config/sweep?service_type=sweep&agent_id=agent-1", bytes.NewReader(buf))
    // Inject mux var {service}
    req = mux.SetURLVars(req, map[string]string{"service": "sweep"})
    rr := httptest.NewRecorder()

    s.handleUpdateConfig(rr, req)

    if rr.Code != http.StatusOK {
        t.Fatalf("expected 200 OK, got %d", rr.Code)
    }
    if gotKey != "agents/agent-1/checkers/sweep/sweep.json" {
        t.Fatalf("unexpected key: %s", gotKey)
    }
    if len(gotBody) == 0 {
        t.Fatalf("expected body passed to kvPutFn")
    }

    // Assert response JSON contains expected fields
    var resp map[string]any
    if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
        t.Fatalf("failed to parse response: %v", err)
    }
    if resp["service"] != "sweep" {
        t.Fatalf("expected service=sweep, got %v", resp["service"])
    }
    if resp["key"] != gotKey {
        t.Fatalf("response key mismatch: %v vs %v", resp["key"], gotKey)
    }
    if resp["status"] != "updated" {
        t.Fatalf("expected status=updated, got %v", resp["status"])
    }
}

func TestHandleUpdateConfig_Snmp_MissingAgent(t *testing.T) {
    s := newTestAPIServer()

    // kvPutFn must not be called in this path
    s.kvPutFn = func(_ context.Context, key string, _ []byte, _ int64) error {
        t.Fatalf("kvPutFn should not be called, key=%s", key)
        return nil
    }

    buf := []byte(`{"community":"public"}`)

    req := httptest.NewRequest(http.MethodPut, "/api/admin/config/snmp?service_type=snmp", bytes.NewReader(buf))
    req = mux.SetURLVars(req, map[string]string{"service": "snmp"})
    rr := httptest.NewRecorder()

    s.handleUpdateConfig(rr, req)

    if rr.Code != http.StatusBadRequest {
        t.Fatalf("expected 400 for missing agent_id, got %d", rr.Code)
    }
}

func TestHandleUpdateConfig_ExplicitKeyOverride(t *testing.T) {
    s := newTestAPIServer()

    var gotKey string
    s.kvPutFn = func(_ context.Context, key string, _ []byte, _ int64) error {
        gotKey = key
        return nil
    }

    req := httptest.NewRequest(http.MethodPut, "/api/admin/config/custom?key=agents/x/checkers/custom/custom.json", bytes.NewReader([]byte(`{"x":1}`)))
    req = mux.SetURLVars(req, map[string]string{"service": "custom"})
    rr := httptest.NewRecorder()

    s.handleUpdateConfig(rr, req)

    if rr.Code != http.StatusOK {
        t.Fatalf("expected 200 OK, got %d", rr.Code)
    }
    if gotKey != "agents/x/checkers/custom/custom.json" {
        t.Fatalf("unexpected key: %s", gotKey)
    }

    var resp map[string]any
    if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
        t.Fatalf("failed to parse response: %v", err)
    }
    if resp["key"] != gotKey {
        t.Fatalf("response key mismatch: %v vs %v", resp["key"], gotKey)
    }
    if resp["status"] != "updated" {
        t.Fatalf("expected status=updated, got %v", resp["status"])
    }
}
