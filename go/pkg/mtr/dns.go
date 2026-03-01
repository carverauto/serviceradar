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
	"context"
	"net"
	"sync"
	"time"
)

const (
	dnsWorkers  = 4
	dnsCacheTTL = 10 * time.Minute
	dnsTimeout  = 2 * time.Second
)

type dnsEntry struct {
	hostname string
	expiry   time.Time
}

// DNSResolver performs async reverse DNS lookups with caching.
type DNSResolver struct {
	cache   map[string]dnsEntry
	mu      sync.RWMutex
	pending chan dnsRequest
	wg      sync.WaitGroup
	cancel  context.CancelFunc
}

type dnsRequest struct {
	ip       string
	callback func(hostname string)
}

// NewDNSResolver creates a resolver with a background worker pool.
func NewDNSResolver(ctx context.Context) *DNSResolver {
	ctx, cancel := context.WithCancel(ctx)

	r := &DNSResolver{
		cache:   make(map[string]dnsEntry),
		pending: make(chan dnsRequest, 256), //nolint:mnd
		cancel:  cancel,
	}

	for range dnsWorkers {
		r.wg.Add(1)

		go r.worker(ctx)
	}

	return r
}

// Resolve queues an async reverse DNS lookup. The callback is invoked
// with the hostname (or empty string) when resolution completes.
// If the result is cached, the callback is invoked immediately.
func (r *DNSResolver) Resolve(ip string, callback func(hostname string)) {
	r.mu.RLock()
	if entry, ok := r.cache[ip]; ok && time.Now().Before(entry.expiry) {
		r.mu.RUnlock()
		callback(entry.hostname)

		return
	}
	r.mu.RUnlock()

	select {
	case r.pending <- dnsRequest{ip: ip, callback: callback}:
	default:
		// Channel full — skip this lookup rather than blocking probes.
		callback("")
	}
}

// LookupSync performs a blocking reverse DNS lookup with cache.
func (r *DNSResolver) LookupSync(ip string) string {
	r.mu.RLock()
	if entry, ok := r.cache[ip]; ok && time.Now().Before(entry.expiry) {
		r.mu.RUnlock()
		return entry.hostname
	}
	r.mu.RUnlock()

	lookupCtx, cancel := context.WithTimeout(context.Background(), dnsTimeout)
	defer cancel()

	hostname := reverseLookup(lookupCtx, ip)
	r.cacheResult(ip, hostname)

	return hostname
}

// Stop shuts down the resolver and waits for workers to finish.
func (r *DNSResolver) Stop() {
	r.cancel()
	r.wg.Wait()
}

func (r *DNSResolver) worker(ctx context.Context) {
	defer r.wg.Done()

	for {
		select {
		case <-ctx.Done():
			return
		case req, ok := <-r.pending:
			if !ok {
				return
			}

			lookupCtx, cancel := context.WithTimeout(ctx, dnsTimeout)
			hostname := reverseLookup(lookupCtx, req.ip)
			cancel()
			r.cacheResult(req.ip, hostname)
			req.callback(hostname)
		}
	}
}

func (r *DNSResolver) cacheResult(ip, hostname string) {
	r.mu.Lock()
	r.cache[ip] = dnsEntry{
		hostname: hostname,
		expiry:   time.Now().Add(dnsCacheTTL),
	}
	r.mu.Unlock()
}

func reverseLookup(ctx context.Context, ip string) string {
	names, err := net.DefaultResolver.LookupAddr(ctx, ip)
	if err != nil || len(names) == 0 {
		return ""
	}

	// Remove trailing dot from FQDN.
	name := names[0]
	if len(name) > 0 && name[len(name)-1] == '.' {
		name = name[:len(name)-1]
	}

	return name
}
