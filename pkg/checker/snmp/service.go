package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
)

type SNMPService struct {
	collectors map[string]*Collector
	config     *Config
	mu         sync.RWMutex
	done       chan struct{}
}

func NewSNMPService(config *Config) (*SNMPService, error) {
	service := &SNMPService{
		collectors: make(map[string]*Collector),
		config:     config,
		done:       make(chan struct{}),
	}

	// Initialize collectors for each target
	for _, target := range config.Targets {
		collector, err := NewCollector(&target)
		if err != nil {
			return nil, fmt.Errorf("failed to create collector for %s: %w", target.Name, err)
		}
		service.collectors[target.Name] = collector
	}

	return service, nil
}

func (s *SNMPService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for name, collector := range s.collectors {
		if err := collector.Start(ctx); err != nil {
			return fmt.Errorf("failed to start collector %s: %w", name, err)
		}
	}

	return nil
}

func (s *SNMPService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	close(s.done)
	for name, collector := range s.collectors {
		if err := collector.Stop(); err != nil {
			log.Printf("Error stopping collector %s: %v", name, err)
		}
	}

	return nil
}

func (s *SNMPService) GetStatus() (json.RawMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	status := make(map[string]interface{})
	for name, collector := range s.collectors {
		targetStatus := make(map[string]interface{})
		for _, oid := range collector.target.OIDs {
			// TODO: Add actual OID status
			targetStatus[oid.Name] = "unknown"
		}
		status[name] = targetStatus
	}

	data, err := json.Marshal(status)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal status: %w", err)
	}

	return data, nil
}
