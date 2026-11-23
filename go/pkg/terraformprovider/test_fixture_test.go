package terraformprovider

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
)

const fixtureID = "11111111-2222-4333-8444-555555555555"
const fixtureKey = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
const fixtureMaterial = "synthetic-test-material-not-a-real-credential"

// apiFixture deliberately implements the public wire contract, not provider
// internals. Everything in this fixture is invented, including trust and IDs.
type apiFixture struct {
	mu                                    sync.Mutex
	object                                map[string]any
	version, requests, rotations, deletes int
	guardDelete, rejectPatch, missing     bool
	createBody                            string
	createKey                             string
	rotateKey                             string
	rotateBody                            string
	rotateVersion                         int
	rotateResponse                        map[string]any
	deletedKeys                           map[string]bool
}

func (f *apiFixture) serve(w http.ResponseWriter, req *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests++
	if req.Header.Get("Authorization") != "Bearer synthetic-api-token" {
		http.Error(w, "denied", http.StatusForbidden)
		return
	}
	if !strings.HasPrefix(req.URL.Path, "/api/admin/") {
		http.Error(w, "wrong route", http.StatusNotFound)
		return
	}
	body, ok := decodeRequestBody(w, req)
	if !ok {
		return
	}
	isCollection := len(strings.Split(strings.Trim(req.URL.Path, "/"), "/")) == 3
	switch {
	case req.Method == http.MethodPost && isCollection:
		if !f.serveCreate(w, req, body) {
			return
		}
	case f.object == nil || f.missing:
		http.Error(w, "missing", http.StatusNotFound)
		return
	case req.Method == http.MethodPost && strings.HasSuffix(req.URL.Path, "/rotate"):
		if !f.serveRotate(w, req, body) {
			return
		}
	case req.Method != http.MethodGet:
		if !f.serveMutation(w, req, body) {
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("ETag", fmt.Sprintf("\"%d\"", f.version))
	if req.Method == http.MethodPost && isCollection {
		w.WriteHeader(http.StatusCreated)
	}
	_ = json.NewEncoder(w).Encode(f.object)
}

func (f *apiFixture) serveCreate(w http.ResponseWriter, req *http.Request, body map[string]any) bool {
	encoded, _ := json.Marshal(body)
	idemKey := req.Header.Get("Idempotency-Key")
	if idemKey != "" && f.deletedKeys[idemKey] {
		http.Error(w, "idempotency_resource_deleted", http.StatusGone)
		return false
	}
	if f.createKey == idemKey && f.createBody != string(encoded) {
		http.Error(w, "idempotency_conflict", http.StatusConflict)
		return false
	}
	if f.object != nil {
		if f.createKey != idemKey || f.createBody != string(encoded) {
			http.Error(w, "conflicting create", http.StatusConflict)
			return false
		}
		return true
	}
	f.createKey, f.createBody = idemKey, string(encoded)
	f.object = normalizeFixtureCreate(req.URL.Path, body)
	f.object["id"] = fixtureID
	f.version++
	return true
}

func (f *apiFixture) serveRotate(w http.ResponseWriter, req *http.Request, body map[string]any) bool {
	encoded, _ := json.Marshal(body)
	idemKey := req.Header.Get("Idempotency-Key")
	if idemKey != "" && f.rotateKey == idemKey {
		if f.rotateBody != string(encoded) {
			http.Error(w, "idempotency_conflict", http.StatusConflict)
			return false
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("ETag", fmt.Sprintf("\"%d\"", f.rotateVersion))
		_ = json.NewEncoder(w).Encode(f.rotateResponse)
		return false
	}
	if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", f.version) {
		http.Error(w, "stale", http.StatusConflict)
		return false
	}
	f.rotations++
	f.version++
	f.rotateKey = idemKey
	f.rotateBody = string(encoded)
	f.rotateVersion = f.version
	f.rotateResponse = cloneJSONMap(f.object)
	return true
}

func (f *apiFixture) serveMutation(w http.ResponseWriter, req *http.Request, body map[string]any) bool {
	if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", f.version) {
		http.Error(w, "stale", http.StatusConflict)
		return false
	}
	switch req.Method {
	case http.MethodDelete:
		f.deletes++
		if f.guardDelete {
			http.Error(w, "in use", http.StatusConflict)
			return false
		}
		if f.createKey != "" {
			if f.deletedKeys == nil {
				f.deletedKeys = map[string]bool{}
			}
			f.deletedKeys[f.createKey] = true
		}
		f.object = nil
		w.WriteHeader(http.StatusNoContent)
		return false
	case http.MethodPatch:
		if f.rejectPatch {
			http.Error(w, fixtureMaterial, http.StatusBadRequest)
			return false
		}
		for key, value := range body {
			f.object[key] = value
		}
		f.version++
		return true
	default:
		http.Error(w, "unexpected action", http.StatusBadRequest)
		return false
	}
}

type fixtureRecord struct {
	id         string
	version    int
	createKey  string
	createBody string
	fields     map[string]any
}

// multiResourceFixture simulates multiple keyed resources across all four
// /api/admin/* collections, server defaults, X-API-Key auth, and enabled guards.
type multiResourceFixture struct {
	mu           sync.Mutex
	apiKey       string
	seq          int
	collections  map[string]map[string]*fixtureRecord
	createKeys   map[string]*fixtureRecord
	deletedKeys  map[string]bool
	rotateEvents map[string]int
}

func newMultiResourceFixture(apiKey string) *multiResourceFixture {
	return &multiResourceFixture{
		apiKey:       apiKey,
		collections:  map[string]map[string]*fixtureRecord{},
		createKeys:   map[string]*fixtureRecord{},
		deletedKeys:  map[string]bool{},
		rotateEvents: map[string]int{},
	}
}

func (m *multiResourceFixture) serve(w http.ResponseWriter, req *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if !m.authorized(req) {
		http.Error(w, "denied", http.StatusForbidden)
		return
	}
	if !strings.HasPrefix(req.URL.Path, "/api/admin/") {
		http.Error(w, "wrong route", http.StatusNotFound)
		return
	}
	parts := strings.Split(strings.Trim(req.URL.Path, "/"), "/")
	if len(parts) < 3 {
		http.Error(w, "wrong route", http.StatusNotFound)
		return
	}
	collection := parts[2]
	body, ok := decodeRequestBody(w, req)
	if !ok {
		return
	}

	switch {
	case len(parts) == 3 && req.Method == http.MethodPost:
		m.handleCreate(w, req, collection, body)
	case len(parts) == 4 && req.Method == http.MethodGet:
		m.handleGet(w, collection, parts[3])
	case len(parts) == 4 && req.Method == http.MethodPatch:
		m.handlePatch(w, req, collection, parts[3], body)
	case len(parts) == 4 && req.Method == http.MethodDelete:
		m.handleDelete(w, req, collection, parts[3])
	case len(parts) == 5 && parts[4] == "rotate" && req.Method == http.MethodPost:
		m.handleRotate(w, req, collection, parts[3])
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

func (m *multiResourceFixture) authorized(req *http.Request) bool {
	if m.apiKey != "" && req.Header.Get("X-API-Key") == m.apiKey {
		return true
	}
	return req.Header.Get("Authorization") == "Bearer synthetic-api-token"
}

func decodeRequestBody(w http.ResponseWriter, req *http.Request) (map[string]any, bool) {
	var body map[string]any
	if req.Body != nil && req.ContentLength != 0 {
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return nil, false
		}
	}
	return body, true
}

func (m *multiResourceFixture) handleCreate(w http.ResponseWriter, req *http.Request, collection string, body map[string]any) {
	encoded, _ := json.Marshal(body)
	idemKey := req.Header.Get("Idempotency-Key")
	if idemKey != "" {
		if m.deletedKeys[idemKey] {
			http.Error(w, "idempotency_resource_deleted", http.StatusGone)
			return
		}
		if existing, ok := m.createKeys[idemKey]; ok {
			if existing.createBody != string(encoded) {
				http.Error(w, "idempotency_conflict", http.StatusConflict)
				return
			}
			writeRecordResponse(w, http.StatusCreated, existing)
			return
		}
	}

	m.seq++
	id := fmt.Sprintf("22222222-3333-4444-8555-%012d", m.seq)
	fields := normalizeFixtureCreate(collection, body)
	fields["id"] = id
	rec := &fixtureRecord{
		id:         id,
		version:    1,
		createKey:  idemKey,
		createBody: string(encoded),
		fields:     fields,
	}
	if m.collections[collection] == nil {
		m.collections[collection] = map[string]*fixtureRecord{}
	}
	m.collections[collection][id] = rec
	if idemKey != "" {
		m.createKeys[idemKey] = rec
	}
	writeRecordResponse(w, http.StatusCreated, rec)
}

func (m *multiResourceFixture) handleGet(w http.ResponseWriter, collection, id string) {
	rec := m.lookup(collection, id)
	if rec == nil {
		http.Error(w, "missing", http.StatusNotFound)
		return
	}
	writeRecordResponse(w, http.StatusOK, rec)
}

func (m *multiResourceFixture) handlePatch(w http.ResponseWriter, req *http.Request, collection, id string, body map[string]any) {
	rec := m.lookup(collection, id)
	if rec == nil {
		http.Error(w, "missing", http.StatusNotFound)
		return
	}
	if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", rec.version) {
		http.Error(w, "stale", http.StatusConflict)
		return
	}
	for k, v := range body {
		rec.fields[k] = v
	}
	rec.version++
	writeRecordResponse(w, http.StatusOK, rec)
}

func (m *multiResourceFixture) handleDelete(w http.ResponseWriter, req *http.Request, collection, id string) {
	rec := m.lookup(collection, id)
	if rec == nil {
		http.Error(w, "missing", http.StatusNotFound)
		return
	}
	if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", rec.version) {
		http.Error(w, "stale", http.StatusConflict)
		return
	}
	if (collection == "network-credential-rules" || collection == "ansible-controllers") && rec.fields["enabled"] == true {
		http.Error(w, "must_be_disabled", http.StatusConflict)
		return
	}
	delete(m.collections[collection], id)
	if rec.createKey != "" {
		m.deletedKeys[rec.createKey] = true
		delete(m.createKeys, rec.createKey)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *multiResourceFixture) handleRotate(w http.ResponseWriter, req *http.Request, collection, id string) {
	rec := m.lookup(collection, id)
	if rec == nil {
		http.Error(w, "missing", http.StatusNotFound)
		return
	}
	if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", rec.version) {
		http.Error(w, "stale", http.StatusConflict)
		return
	}
	rec.version++
	m.rotateEvents[id]++
	writeRecordResponse(w, http.StatusOK, rec)
}

func (m *multiResourceFixture) lookup(collection, id string) *fixtureRecord {
	col := m.collections[collection]
	if col == nil {
		return nil
	}
	return col[id]
}

func (m *multiResourceFixture) mutateField(collection, id, key string, value any) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if rec := m.lookup(collection, id); rec != nil {
		rec.fields[key] = value
		rec.version++
	}
}

func writeRecordResponse(w http.ResponseWriter, status int, rec *fixtureRecord) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("ETag", fmt.Sprintf("\"%d\"", rec.version))
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(rec.fields)
}

func normalizeFixtureCreate(pathOrCollection string, body map[string]any) map[string]any {
	obj := cloneJSONMap(body)
	delete(obj, "values")

	switch {
	case strings.Contains(pathOrCollection, "credential-secrets"):
		if method, ok := obj["auth_method"]; ok {
			obj["metadata"] = map[string]any{"auth_method": method, "unrelated": fixtureMaterial}
			delete(obj, "auth_method")
		}
		obj["credential_kind"] = "token"
		obj["rotation_state"] = "active"
	case strings.Contains(pathOrCollection, "credential-rules"):
		setDefault(obj, "enabled", true)
		setDefault(obj, "priority", float64(100))
		setDefault(obj, "allowed_ports", []any{})
		setDefault(obj, "tls_policy", "verify")
		setDefault(obj, "ssh_host_key_policy", "known_hosts")
	case strings.Contains(pathOrCollection, "ansible-controllers"):
		setDefault(obj, "enabled", true)
		setDefault(obj, "inventory_sync_interval_seconds", float64(300))
		setDefault(obj, "catalog_sync_interval_seconds", float64(600))
		setDefault(obj, "status", "unknown")
	case strings.Contains(pathOrCollection, "ansible-repositories"):
		setDefault(obj, "git_ref", "main")
		setDefault(obj, "sync_interval_seconds", float64(600))
		setDefault(obj, "last_sync_status", "pending")
	}
	return obj
}

func setDefault(m map[string]any, key string, value any) {
	if _, exists := m[key]; !exists {
		m[key] = value
	}
}

func cloneJSONMap(in map[string]any) map[string]any {
	if in == nil {
		return map[string]any{}
	}
	encoded, _ := json.Marshal(in)
	var out map[string]any
	_ = json.Unmarshal(encoded, &out)
	return out
}
