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
	var body map[string]any
	if req.Body != nil && req.ContentLength != 0 {
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
	}
	isCollection := len(strings.Split(strings.Trim(req.URL.Path, "/"), "/")) == 3
	switch {
	case req.Method == http.MethodPost && isCollection:
		encoded, _ := json.Marshal(body)
		if f.createKey == req.Header.Get("Idempotency-Key") && f.createBody != string(encoded) {
			http.Error(w, "idempotency_conflict", http.StatusConflict)
			return
		}
		if f.object != nil {
			if f.createKey != req.Header.Get("Idempotency-Key") || f.createBody != string(encoded) {
				http.Error(w, "conflicting create", http.StatusConflict)
				return
			}
		} else {
			f.createKey, f.createBody = req.Header.Get("Idempotency-Key"), string(encoded)
			f.object = body
			delete(f.object, "values")
			f.object["id"] = fixtureID
			if method, ok := f.object["auth_method"]; ok && strings.Contains(req.URL.Path, "credential-secrets") {
				f.object["metadata"] = map[string]any{"auth_method": method, "unrelated": fixtureMaterial}
				delete(f.object, "auth_method")
				f.object["credential_kind"] = "token"
			}
			if strings.Contains(req.URL.Path, "ansible-repositories") {
				f.object["git_ref"], f.object["sync_interval_seconds"], f.object["last_sync_status"] = "main", float64(600), "pending"
			}
			f.version++
		}
	case f.object == nil || f.missing:
		http.Error(w, "missing", http.StatusNotFound)
		return
	case req.Method != http.MethodGet:
		if req.Header.Get("If-Match") != fmt.Sprintf("\"%d\"", f.version) {
			http.Error(w, "stale", http.StatusConflict)
			return
		}
		switch req.Method {
		case http.MethodDelete:
			f.deletes++
			if f.guardDelete {
				http.Error(w, "in use", http.StatusConflict)
				return
			}
			f.object = nil
			w.WriteHeader(http.StatusNoContent)
			return
		case http.MethodPatch:
			if f.rejectPatch {
				http.Error(w, fixtureMaterial, http.StatusBadRequest)
				return
			}
			for key, value := range body {
				f.object[key] = value
			}
			f.version++
		case http.MethodPost:
			if !strings.HasSuffix(req.URL.Path, "/rotate") {
				http.Error(w, "unexpected action", http.StatusBadRequest)
				return
			}
			f.rotations++
			f.version++
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("ETag", fmt.Sprintf("\"%d\"", f.version))
	if req.Method == http.MethodPost && isCollection {
		w.WriteHeader(http.StatusCreated)
	}
	_ = json.NewEncoder(w).Encode(f.object)
}
