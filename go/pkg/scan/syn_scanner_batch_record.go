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
	"net"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func (s *SYNScanner) recordSynBatchTarget(target models.Target, key string, srcPort uint16, dst4, dst16 net.IP, ipv6 bool, grace time.Duration) {
	s.mu.Lock()
	if s.portTargetMap == nil {
		s.portTargetMap = make(map[uint16]string)
	}
	if s.targetPorts == nil {
		s.targetPorts = make(map[string][]uint16)
	}
	if s.targetIP == nil {
		s.targetIP = make(map[string]string)
	}
	if s.results == nil {
		s.results = make(map[string]models.Result)
	}

	s.portTargetMap[srcPort] = key
	s.targetPorts[key] = append(s.targetPorts[key], srcPort)
	if ipv6 {
		s.targetIP[key] = dst16.String()
	} else {
		s.targetIP[key] = dst4.String()
	}

	if existing, ok := s.results[key]; ok && !existing.FirstSeen.IsZero() {
		existing.LastSeen = time.Now()
		s.results[key] = existing
	} else {
		s.results[key] = models.Result{
			Target:    target,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}
	}

	s.portDeadline[srcPort] = time.Now().Add(s.timeout + grace)
	s.mu.Unlock()
}

func (s *SYNScanner) buildSynBatchEntry(target models.Target, key string, srcPort uint16, dst4, dst16 net.IP, ipv6 bool) synBatchEntry {
	entry := synBatchEntry{
		ipv6:      ipv6,
		srcPort:   srcPort,
		targetKey: key,
		target:    target,
	}

	if ipv6 {
		copy(entry.dst6[:], dst16)
		entry.packet = buildSYNPacketIPv6(s.sourceIP6, dst16, srcPort, uint16(target.Port), s.randUint32())
	} else {
		copy(entry.dst4[:], dst4)
		entry.packet = s.buildSynPacketFromTemplate(s.sourceIP, dst4, srcPort, uint16(target.Port))
		entry.pooled = true
	}

	return entry
}
