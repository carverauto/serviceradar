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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/mapper"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const mapperServiceType = "mapper"

var (
	errMapperConfigRequired    = errors.New("mapper config required")
	errMapperEngineNotRunning  = errors.New("mapper engine not initialized")
	errMapperUpdateUnsupported = errors.New("mapper UpdateConfig is not supported")
	errMapperRunUnsupported    = errors.New("mapper run_now not supported")
)

// MapperService wraps the mapper discovery engine for embedded agent use.
type MapperService struct {
	mu           sync.RWMutex
	logger       logger.Logger
	config       *mapper.Config
	engine       mapper.Mapper
	publisher    *MapperResultPublisher
	configHash   string
	engineCtx    context.Context
	engineCancel context.CancelFunc
}

func NewMapperService(cfg *mapper.Config, log logger.Logger) (*MapperService, error) {
	if cfg == nil {
		return nil, errMapperConfigRequired
	}

	publisher := NewMapperResultPublisher()
	engine, err := mapper.NewDiscoveryEngine(cfg, publisher, log)
	if err != nil {
		return nil, err
	}

	return &MapperService{
		logger:    log,
		config:    cfg,
		engine:    engine,
		publisher: publisher,
	}, nil
}

func (s *MapperService) Start(ctx context.Context) error {
	s.mu.RLock()
	engine := s.engine
	s.mu.RUnlock()

	if engine == nil {
		return errMapperEngineNotRunning
	}

	return engine.Start(ctx)
}

func (s *MapperService) Stop(ctx context.Context) error {
	s.mu.Lock()
	engine := s.engine
	engineCancel := s.engineCancel
	s.mu.Unlock()

	if engine == nil {
		return nil
	}

	// Cancel the engine context to signal workers to stop
	if engineCancel != nil {
		engineCancel()
	}

	return engine.Stop(ctx)
}

func (*MapperService) Name() string {
	return "network_mapper"
}

func (s *MapperService) UpdateConfig(cfg *models.Config) error {
	if cfg == nil {
		return errMapperConfigRequired
	}

	return errMapperUpdateUnsupported
}

func (s *MapperService) ApplyMapperConfig(cfg *mapper.Config, hash string) error {
	if cfg == nil {
		return errMapperConfigRequired
	}

	return s.applyConfigWithHash(cfg, hash)
}

func (s *MapperService) applyConfigWithHash(cfg *mapper.Config, hash string) error {
	if cfg == nil {
		return errMapperConfigRequired
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.configHash != "" && hash != "" && s.configHash == hash {
		return nil
	}

	// Stop existing engine and cancel its context
	if s.engine != nil {
		stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = s.engine.Stop(stopCtx)
		cancel()
	}

	if s.engineCancel != nil {
		s.engineCancel()
	}

	publisher := NewMapperResultPublisher()
	engine, err := mapper.NewDiscoveryEngine(cfg, publisher, s.logger)
	if err != nil {
		return err
	}

	// Create a long-lived context for the engine that won't be canceled
	// when this function returns. It will only be canceled when Stop is called
	// or when a new config is applied.
	engineCtx, engineCancel := context.WithCancel(context.Background())

	if err := engine.Start(engineCtx); err != nil {
		engineCancel()
		return err
	}

	s.config = cfg
	s.engine = engine
	s.publisher = publisher
	s.engineCtx = engineCtx
	s.engineCancel = engineCancel
	if hash != "" {
		s.configHash = hash
	}

	return nil
}

func (s *MapperService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}

func (s *MapperService) RunScheduledJob(ctx context.Context, jobName string) (string, error) {
	s.mu.RLock()
	engine := s.engine
	s.mu.RUnlock()

	if engine == nil {
		return "", errMapperEngineNotRunning
	}

	runner, ok := engine.(interface {
		RunScheduledJob(context.Context, string) (string, error)
	})
	if !ok {
		return "", errMapperRunUnsupported
	}

	return runner.RunScheduledJob(ctx, jobName)
}

func (s *MapperService) DrainResults(max int) ([]map[string]interface{}, bool) {
	s.mu.RLock()
	publisher := s.publisher
	s.mu.RUnlock()

	if publisher == nil {
		return nil, false
	}

	return publisher.Drain(max)
}

func (s *MapperService) DrainInterfaces(max int) ([]map[string]interface{}, bool) {
	s.mu.RLock()
	publisher := s.publisher
	s.mu.RUnlock()

	if publisher == nil {
		return nil, false
	}

	return publisher.DrainInterfaces(max)
}

func (s *MapperService) DrainTopology(max int) ([]map[string]interface{}, bool) {
	s.mu.RLock()
	publisher := s.publisher
	s.mu.RUnlock()

	if publisher == nil {
		return nil, false
	}

	return publisher.DrainTopology(max)
}

// MapperResultPublisher buffers discovered devices for push-based ingestion.
type MapperResultPublisher struct {
	mu      sync.Mutex
	results []map[string]interface{}
	ifaces  []map[string]interface{}
	links   []map[string]interface{}
	seq     uint64
}

func NewMapperResultPublisher() *MapperResultPublisher {
	return &MapperResultPublisher{
		results: make([]map[string]interface{}, 0, 256),
		ifaces:  make([]map[string]interface{}, 0, 256),
		links:   make([]map[string]interface{}, 0, 256),
	}
}

func (p *MapperResultPublisher) PublishDevice(_ context.Context, device *mapper.DiscoveredDevice) error {
	if device == nil {
		return nil
	}

	update := map[string]interface{}{
		"device_id":    device.DeviceID,
		"ip":           device.IP,
		"source":       models.DiscoverySourceMapper,
		"timestamp":    time.Now().UTC().Format(time.RFC3339Nano),
		"is_available": true,
		"metadata":     buildMapperDeviceMetadata(device),
	}

	if device.Hostname != "" {
		update["hostname"] = device.Hostname
	}
	if device.MAC != "" {
		update["mac"] = device.MAC
	}

	p.mu.Lock()
	p.results = append(p.results, update)
	p.seq++
	p.mu.Unlock()

	return nil
}

func (p *MapperResultPublisher) PublishInterface(_ context.Context, iface *mapper.DiscoveredInterface) error {
	if iface == nil {
		return nil
	}

	update := map[string]interface{}{
		"device_id":         iface.DeviceID,
		"device_ip":         iface.DeviceIP,
		"if_index":          iface.IfIndex,
		"if_name":           iface.IfName,
		"if_descr":          iface.IfDescr,
		"if_alias":          iface.IfAlias,
		"if_speed":          iface.IfSpeed,
		"if_phys_address":   iface.IfPhysAddress,
		"ip_addresses":      iface.IPAddresses,
		"if_admin_status":   iface.IfAdminStatus,
		"if_oper_status":    iface.IfOperStatus,
		"if_type":           iface.IfType,
		"metadata":          iface.Metadata,
		"available_metrics": iface.AvailableMetrics,
		"timestamp":         time.Now().UTC().Format(time.RFC3339Nano),
	}

	p.mu.Lock()
	p.ifaces = append(p.ifaces, update)
	p.seq++
	p.mu.Unlock()

	return nil
}

func (p *MapperResultPublisher) PublishTopologyLink(_ context.Context, link *mapper.TopologyLink) error {
	if link == nil {
		return nil
	}

	update := map[string]interface{}{
		"protocol":             link.Protocol,
		"local_device_ip":      link.LocalDeviceIP,
		"local_device_id":      link.LocalDeviceID,
		"local_if_index":       link.LocalIfIndex,
		"local_if_name":        link.LocalIfName,
		"neighbor_chassis_id":  link.NeighborChassisID,
		"neighbor_port_id":     link.NeighborPortID,
		"neighbor_port_descr":  link.NeighborPortDescr,
		"neighbor_system_name": link.NeighborSystemName,
		"neighbor_mgmt_addr":   link.NeighborMgmtAddr,
		"metadata":             link.Metadata,
		"timestamp":            time.Now().UTC().Format(time.RFC3339Nano),
	}

	p.mu.Lock()
	p.links = append(p.links, update)
	p.seq++
	p.mu.Unlock()

	return nil
}

func (p *MapperResultPublisher) Drain(max int) ([]map[string]interface{}, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if len(p.results) == 0 {
		return nil, false
	}

	if max <= 0 || max > len(p.results) {
		max = len(p.results)
	}

	batch := make([]map[string]interface{}, max)
	copy(batch, p.results[:max])
	p.results = p.results[max:]

	return batch, true
}

func (p *MapperResultPublisher) DrainInterfaces(max int) ([]map[string]interface{}, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if len(p.ifaces) == 0 {
		return nil, false
	}

	if max <= 0 || max > len(p.ifaces) {
		max = len(p.ifaces)
	}

	batch := make([]map[string]interface{}, max)
	copy(batch, p.ifaces[:max])
	p.ifaces = p.ifaces[max:]

	return batch, true
}

func (p *MapperResultPublisher) DrainTopology(max int) ([]map[string]interface{}, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if len(p.links) == 0 {
		return nil, false
	}

	if max <= 0 || max > len(p.links) {
		max = len(p.links)
	}

	batch := make([]map[string]interface{}, max)
	copy(batch, p.links[:max])
	p.links = p.links[max:]

	return batch, true
}

func buildMapperDeviceMetadata(device *mapper.DiscoveredDevice) map[string]string {
	metadata := map[string]string{
		"source":    "mapper",
		"device_id": device.DeviceID,
	}

	if device.SysDescr != "" {
		metadata["sys_descr"] = device.SysDescr
	}
	if device.SysObjectID != "" {
		metadata["sys_object_id"] = device.SysObjectID
	}
	if device.SysContact != "" {
		metadata["sys_contact"] = device.SysContact
	}
	if device.SysLocation != "" {
		metadata["sys_location"] = device.SysLocation
	}
	if device.Uptime != 0 {
		metadata["uptime"] = fmt.Sprintf("%d", device.Uptime)
	}

	for key, value := range device.Metadata {
		metadata[key] = value
	}

	return metadata
}

func buildMapperResultsPayload(updates []map[string]interface{}, agentID, partition string) ([]byte, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	for _, update := range updates {
		if update == nil {
			continue
		}
		if update["agent_id"] == nil {
			update["agent_id"] = agentID
		}
		if update["gateway_id"] == nil {
			update["gateway_id"] = agentID
		}
		if partition == "" {
			partition = defaultPartition
		}
		if update["partition"] == nil {
			update["partition"] = partition
		}
		meta, _ := update["metadata"].(map[string]string)
		if meta == nil {
			meta = map[string]string{}
		}
		if _, ok := meta["sync_service_id"]; !ok && agentID != "" {
			meta["sync_service_id"] = agentID
		}
		update["metadata"] = meta
		if id, ok := update["device_id"].(string); !ok || id == "" {
			if ip, ok := update["ip"].(string); ok && ip != "" {
				update["device_id"] = fmt.Sprintf("%s:%s", partition, ip)
			}
		}
	}

	return json.Marshal(updates)
}

func buildMapperInterfacePayload(updates []map[string]interface{}, agentID, partition string) ([]byte, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	if partition == "" {
		partition = defaultPartition
	}

	for _, update := range updates {
		if update == nil {
			continue
		}

		if update["agent_id"] == nil {
			update["agent_id"] = agentID
		}
		if update["gateway_id"] == nil {
			update["gateway_id"] = agentID
		}
		if update["partition"] == nil {
			update["partition"] = partition
		}
		if id, ok := update["device_id"].(string); !ok || id == "" {
			if ip, ok := update["device_ip"].(string); ok && ip != "" {
				update["device_id"] = fmt.Sprintf("%s:%s", partition, ip)
			}
		}
	}

	return json.Marshal(updates)
}

func buildMapperTopologyPayload(updates []map[string]interface{}, agentID, partition string) ([]byte, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	if partition == "" {
		partition = defaultPartition
	}

	for _, update := range updates {
		if update == nil {
			continue
		}
		if update["agent_id"] == nil {
			update["agent_id"] = agentID
		}
		if update["gateway_id"] == nil {
			update["gateway_id"] = agentID
		}
		if update["partition"] == nil {
			update["partition"] = partition
		}
		if id, ok := update["local_device_id"].(string); !ok || id == "" {
			if ip, ok := update["local_device_ip"].(string); ok && ip != "" {
				update["local_device_id"] = fmt.Sprintf("%s:%s", partition, ip)
			}
		}
		if _, ok := update["neighbor_device_id"]; !ok {
			if ip, ok := update["neighbor_mgmt_addr"].(string); ok && ip != "" {
				update["neighbor_device_id"] = fmt.Sprintf("%s:%s", partition, ip)
			}
		}
	}

	return json.Marshal(updates)
}

func mapperResultsResponse(payload []byte, seq, serviceName, serviceType string) *proto.ResultsResponse {
	if len(payload) == 0 {
		return &proto.ResultsResponse{
			Available:       true,
			Data:            []byte("[]"),
			ServiceName:     serviceName,
			ServiceType:     serviceType,
			Timestamp:       time.Now().UnixNano(),
			CurrentSequence: seq,
			HasNewData:      false,
		}
	}

	return &proto.ResultsResponse{
		Available:       true,
		Data:            payload,
		ServiceName:     serviceName,
		ServiceType:     serviceType,
		Timestamp:       time.Now().UnixNano(),
		CurrentSequence: seq,
		HasNewData:      true,
	}
}
