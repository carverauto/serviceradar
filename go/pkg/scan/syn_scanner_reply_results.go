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

func (s *SYNScanner) processTCPFinalResult(peerIP net.IP, localSrcPort, targetPort uint16, available bool, resultErr error) {
	// Update stats counter for each parsed packet
	atomic.AddUint64(&s.stats.PacketsRecv, 1)

	// Precompute inexpensive bits *outside* the lock.
	now := time.Now()

	src := canonicalIPString(peerIP.String())
	if src == "" {
		return
	}

	// We minimize time under s.mu. All map mutation stays inside; any potentially
	// blocking work (callback -> channel send) happens after we unlock.
	var (
		emit      bool
		toEmit    models.Result
		cb        func(models.Result)
		targetKey string
		toFree    = make([]uint16, 0, 8) // Pre-allocate with reasonable capacity
	)

	s.mu.Lock()

	var ok bool

	targetKey, ok = s.portTargetMap[localSrcPort]
	if !ok {
		s.mu.Unlock()
		return
	}

	if !sameCanonicalIPString(src, s.targetIP[targetKey]) {
		s.mu.Unlock()
		return
	}

	result := s.results[targetKey]
	if result.Target.Port != int(targetPort) {
		s.mu.Unlock()
		return
	}

	if result.Available || result.Error != nil {
		s.mu.Unlock()
		return
	}

	result.Available = available
	result.Error = resultErr
	emit = true

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = now

	// Persist the updated result.
	s.results[targetKey] = result

	// Remove all src-port mappings for this target and free them after unlock.
	// Use reverse index for O(k) lookup and dedupe to avoid double release.
	ports := s.targetPorts[targetKey]

	// Track successful retries: if more than one source port was used, a retry succeeded
	if emit && len(ports) > 1 {
		atomic.AddUint64(&s.stats.RetriesSuccessful, 1)
	}

	uniq := make(map[uint16]struct{}, len(ports))

	delete(s.targetPorts, targetKey)

	for _, sp := range ports {
		if _, seen := uniq[sp]; seen {
			continue
		}

		uniq[sp] = struct{}{}
	}

	for sp := range uniq {
		toFree = append(toFree, sp)
	}

	// If we want to emit, capture the callback and a copy of the result *under the lock*,
	// then invoke it after unlocking to avoid holding s.mu during a possibly blocking send.
	if emit && s.resultCallback != nil {
		toEmit = result
		cb = s.resultCallback
	}

	s.mu.Unlock()

	// Release ports outside the lock, using tryReleaseMapping to maintain data structure consistency
	for _, sp := range toFree {
		s.tryReleaseMapping(sp, targetKey)
	}

	if emit && cb != nil {
		cb(toEmit)
	}
}

// handleLoopbackTarget handles TCP scanning for loopback addresses using connect()
func (s *SYNScanner) handleLoopbackTarget(ctx context.Context, target models.Target) {
	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	result := models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Use simple connect() for loopback targets
	d := net.Dialer{Timeout: s.timeout}

	addr := net.JoinHostPort(target.Host, fmt.Sprintf("%d", target.Port))

	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		result.Available = false
		result.Error = err
	} else {
		result.Available = true

		if closeErr := conn.Close(); closeErr != nil {
			s.logger.Debug().Err(closeErr).Msg("Failed to close connection")
		}
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = time.Now()

	// Store & emit without holding s.mu inside the callback.
	s.emitResult(targetKey, result)
}
