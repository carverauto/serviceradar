//go:build linux
// +build linux

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

package scan

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// sendSynBatch crafts and sends SYNs for a slice of targets using sendmmsg().
// Only the *first attempt* should use this fast path; retries can go through sendSyn() or another batcher.
func (s *SYNScanner) sendSynBatch(ctx context.Context, targets []models.Target) []models.Target {
	entries := s.prepareSynBatchEntries(ctx, targets)

	if len(entries) == 0 {
		return nil
	}

	entries4 := make([]synBatchEntry, 0, len(entries))
	entries6 := make([]synBatchEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.ipv6 {
			entries6 = append(entries6, entry)
		} else {
			entries4 = append(entries4, entry)
		}
	}

	sent4 := s.sendSynBatchFamily(s.sendSocket, entries4, false)
	sent6 := s.sendSynBatchFamily(s.sendSocket6, entries6, true)
	sent := make([]models.Target, 0, len(sent4)+len(sent6))

	for i := range sent4 {
		sent = append(sent, sent4[i].target)
	}

	for i := range sent6 {
		sent = append(sent, sent6[i].target)
	}

	return sent
}

func (s *SYNScanner) prepareSynBatchEntries(ctx context.Context, targets []models.Target) []synBatchEntry {
	entries := make([]synBatchEntry, 0, len(targets))
	grace := s.timeout / 4
	if grace > 200*time.Millisecond {
		grace = 200 * time.Millisecond
	}

	for _, target := range targets {
		entry, ok := s.prepareSynBatchEntry(ctx, target, grace)
		if ok {
			entries = append(entries, entry)
		}
	}

	return entries
}

func (s *SYNScanner) prepareSynBatchEntry(ctx context.Context, target models.Target, grace time.Duration) (synBatchEntry, bool) {
	if target.Port <= 0 || target.Port > maxPortNumber {
		return synBatchEntry{}, false
	}

	dst := net.ParseIP(target.Host)
	if dst == nil {
		return synBatchEntry{}, false
	}

	if dst.IsLoopback() {
		s.handleLoopbackTarget(ctx, target)

		return synBatchEntry{}, false
	}

	dst4 := dst.To4()
	dst16 := dst.To16()
	ipv6 := dst4 == nil

	if ipv6 {
		if dst16 == nil || s.sendSocket6 == 0 || s.sourceIP6.To16() == nil || s.sourceIP6.To4() != nil {
			return synBatchEntry{}, false
		}
	} else if dst4 == nil {
		return synBatchEntry{}, false
	}

	key := fmt.Sprintf("%s:%d", target.Host, target.Port)
	if s.hasFinalResult(key) {
		return synBatchEntry{}, false
	}

	srcPort, err := s.portAlloc.Reserve(ctx)
	if err != nil {
		atomic.AddUint64(&s.stats.PortExhaustion, 1)

		return synBatchEntry{}, false
	}
	atomic.AddUint64(&s.stats.PortsAllocated, 1)

	s.recordSynBatchTarget(target, key, srcPort, dst4, dst16, ipv6, grace)

	entry := s.buildSynBatchEntry(target, key, srcPort, dst4, dst16, ipv6)
	if len(entry.packet) == 0 {
		s.tryReleaseMapping(srcPort, key)

		return synBatchEntry{}, false
	}

	return entry, true
}
