/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
)

func (s *Server) ensureBumblebeeSpoolService(cfg *BumblebeeStatusConfig) {
	if s == nil {
		return
	}
	if cfg == nil {
		cfg = &BumblebeeStatusConfig{}
	}
	cfg.Enabled = true

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.config != nil {
		s.config.Bumblebee = cfg
	}
	if s.hasStatusServiceLocked(bumblebee.ServiceName, bumblebee.ServiceType) {
		return
	}

	agentID := ""
	if s.config != nil {
		agentID = s.config.AgentID
	}
	s.services = append(s.services, NewBumblebeeSpoolService(agentID, cfg))
}

func (s *Server) ensureEndpointInventorySpoolService(cfg *EndpointInventoryStatusConfig) {
	if s == nil {
		return
	}
	if cfg == nil {
		cfg = &EndpointInventoryStatusConfig{}
	}
	cfg.Enabled = true

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.config != nil {
		s.config.EndpointInventory = cfg
	}
	if s.hasStatusServiceLocked(endpointinventory.ServiceName, endpointinventory.ServiceType) {
		return
	}

	agentID := ""
	if s.config != nil {
		agentID = s.config.AgentID
	}
	s.services = append(s.services, NewEndpointInventorySpoolService(agentID, cfg))
}

func (s *Server) ensureK8sPublicEndpointsSpoolService(cfg *K8sPublicEndpointsStatusConfig) {
	if s == nil {
		return
	}
	if cfg == nil {
		cfg = &K8sPublicEndpointsStatusConfig{}
	}
	cfg.Enabled = true

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.config != nil {
		s.config.K8sPublicEndpoints = cfg
	}
	if s.hasStatusServiceLocked(K8sPublicEndpointsServiceName, K8sPublicEndpointsServiceType) {
		return
	}

	agentID := ""
	if s.config != nil {
		agentID = s.config.AgentID
	}
	s.services = append(s.services, NewK8sPublicEndpointsSpoolService(agentID, cfg))
}

func (s *Server) hasStatusServiceLocked(name, serviceType string) bool {
	for _, svc := range s.services {
		if svc == nil || svc.Name() != name {
			continue
		}
		routing, ok := svc.(StatusRoutingProvider)
		if !ok || routing.StatusServiceType() == serviceType {
			return true
		}
	}

	return false
}
