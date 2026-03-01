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
	"fmt"
	"net"
	"sync"

	"github.com/oschwald/maxminddb-golang"
)

// mmdbASNRecord is the structure expected from GeoLite2-ASN.mmdb lookups.
type mmdbASNRecord struct {
	ASN int    `maxminddb:"autonomous_system_number"`
	Org string `maxminddb:"autonomous_system_organization"`
}

// Enricher provides ASN lookup from a GeoLite2-ASN MMDB database.
type Enricher struct {
	mu sync.RWMutex
	db *maxminddb.Reader
}

// NewEnricher opens the MMDB file at the given path. Returns a no-op
// enricher (with nil db) if the file cannot be opened, enabling
// graceful degradation.
func NewEnricher(dbPath string) (*Enricher, error) {
	if dbPath == "" {
		return &Enricher{}, nil
	}

	db, err := maxminddb.Open(dbPath)
	if err != nil {
		return &Enricher{}, fmt.Errorf("open MMDB %s: %w", dbPath, err)
	}

	return &Enricher{db: db}, nil
}

// LookupASN returns ASN information for the given IP. Returns an empty
// ASNInfo if the database is unavailable or the IP is not found.
func (e *Enricher) LookupASN(ip net.IP) ASNInfo {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if e.db == nil {
		return ASNInfo{}
	}

	var record mmdbASNRecord
	if err := e.db.Lookup(ip, &record); err != nil {
		return ASNInfo{}
	}

	return ASNInfo{
		ASN: record.ASN,
		Org: record.Org,
	}
}

// EnrichHops adds ASN information to each hop result in place.
func (e *Enricher) EnrichHops(hops []*HopResult) {
	e.mu.RLock()
	if e.db == nil {
		e.mu.RUnlock()
		return
	}
	e.mu.RUnlock()

	for _, hop := range hops {
		hop.mu.Lock()
		if hop.Addr != nil {
			hop.ASN = e.LookupASN(hop.Addr)
		}
		hop.mu.Unlock()
	}
}

// Close releases the MMDB database resources.
func (e *Enricher) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.db != nil {
		return e.db.Close()
	}

	return nil
}
