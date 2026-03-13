/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package mtr

import (
	"net"
	"testing"
)

func TestNewEnricher_EmptyPath(t *testing.T) {
	e, err := NewEnricher("")
	if err != nil {
		t.Fatalf("NewEnricher(\"\") returned error: %v", err)
	}
	if e == nil {
		t.Fatal("NewEnricher(\"\") returned nil enricher")
		return
	}
	if e.db != nil {
		t.Fatal("expected nil db for empty path enricher")
	}
}

func TestNewEnricher_MissingFile(t *testing.T) {
	e, err := NewEnricher("/nonexistent/path/to/GeoLite2-ASN.mmdb")
	if err == nil {
		t.Fatal("expected error for missing MMDB file")
	}
	// Should still return a usable (no-op) enricher
	if e == nil {
		t.Fatal("expected non-nil enricher even on error")
		return
	}
	if e.db != nil {
		t.Fatal("expected nil db for failed open")
	}
}

func TestLookupASN_NilDB(t *testing.T) {
	e := &Enricher{} // nil db
	ip := net.ParseIP("8.8.8.8")

	info := e.LookupASN(ip)
	if info.ASN != 0 {
		t.Errorf("expected ASN 0 for nil db, got %d", info.ASN)
	}
	if info.Org != "" {
		t.Errorf("expected empty Org for nil db, got %q", info.Org)
	}
}

func TestLookupASN_NilIP(t *testing.T) {
	e := &Enricher{} // nil db

	info := e.LookupASN(nil)
	if info.ASN != 0 {
		t.Errorf("expected ASN 0 for nil IP, got %d", info.ASN)
	}
}

func TestEnrichHops_NilDB(t *testing.T) {
	e := &Enricher{} // nil db

	hops := []*HopResult{
		NewHopResult(1, 200),
		NewHopResult(2, 200),
	}
	hops[0].Addr = net.ParseIP("8.8.8.8")
	hops[1].Addr = net.ParseIP("1.1.1.1")

	// Should not panic
	e.EnrichHops(hops)

	// ASN fields should remain zero-valued
	for i, hop := range hops {
		hop.mu.Lock()
		if hop.ASN.ASN != 0 {
			t.Errorf("hop %d: expected ASN 0 after no-op enrich, got %d", i, hop.ASN.ASN)
		}
		hop.mu.Unlock()
	}
}

func TestEnrichHops_NilHopAddr(t *testing.T) {
	e := &Enricher{} // nil db

	hops := []*HopResult{
		NewHopResult(1, 200),
	}
	// Addr is nil (non-responding hop)

	// Should not panic
	e.EnrichHops(hops)
}

func TestEnrichHops_EmptySlice(t *testing.T) {
	e := &Enricher{}

	// Should not panic on empty slice
	e.EnrichHops(nil)
	e.EnrichHops([]*HopResult{})
}

func TestClose_NilDB(t *testing.T) {
	e := &Enricher{}
	err := e.Close()
	if err != nil {
		t.Errorf("Close() on nil db returned error: %v", err)
	}
}

func TestClose_CalledTwice(t *testing.T) {
	e := &Enricher{}
	if err := e.Close(); err != nil {
		t.Errorf("first Close() returned error: %v", err)
	}
	if err := e.Close(); err != nil {
		t.Errorf("second Close() returned error: %v", err)
	}
}
