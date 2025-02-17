package agent

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/pkg/checker/snmp"
	"github.com/mfreeman451/serviceradar/pkg/config"
	"github.com/mfreeman451/serviceradar/proto"
)

// SNMPChecker implements the checker.Checker interface
type SNMPChecker struct {
	service       *snmp.SNMPService
	config        *snmp.Config
	pollerService *snmp.PollerService
}

func NewSNMPChecker(address string) (checker.Checker, error) {
	log.Printf("Creating new SNMP checker for address: %s", address)

	configPath := filepath.Join("/etc/serviceradar/checkers", "snmp.json")
	log.Printf("Loading SNMP config from: %s", configPath)

	// Check if config file exists
	if _, err := os.Stat(configPath); err != nil {
		log.Printf("Config file error: %v", err)
		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg snmp.Config
	if err := config.LoadAndValidate(configPath, &cfg); err != nil {
		log.Printf("Failed to load SNMP config: %v", err)
		return nil, fmt.Errorf("failed to load SNMP config: %w", err)
	}

	log.Printf("Loaded SNMP config: NodeAddress=%s, ListenAddr=%s, Targets=%d",
		cfg.NodeAddress, cfg.ListenAddr, len(cfg.Targets))

	for i, target := range cfg.Targets {
		log.Printf("Target %d: Name=%s Host=%s Port=%d OIDs=%d",
			i, target.Name, target.Host, target.Port, len(target.OIDs))
	}

	cfg.NodeAddress = address

	log.Printf("Creating SNMP service with updated NodeAddress: %s", cfg.NodeAddress)

	service, err := snmp.NewSNMPService(&cfg)
	if err != nil {
		log.Printf("Failed to create SNMP service: %v", err)
		return nil, fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Create Poller and PollerService
	poller := &snmp.Poller{Config: cfg}
	pollerService := snmp.NewSNMPPollerService(poller, service) // Pass the service

	c := &SNMPChecker{
		service:       service,
		config:        &cfg,
		pollerService: pollerService, // Store the poller service
	}

	log.Printf("Successfully created SNMP checker for %s", address)

	// Start the SNMP Service
	ctx := context.Background() // Or use a more appropriate context
	if err := service.Start(ctx); err != nil {
		log.Printf("Failed to start SNMP service: %v", err)
		return nil, fmt.Errorf("failed to start SNMP service: %w", err)
	}

	return c, nil
}

func (c *SNMPChecker) Check(ctx context.Context) (bool, string) {
	// Call the GetStatus function on pollerService and return values
	statusResponse, err := c.pollerService.GetStatus(ctx, &proto.StatusRequest{})
	if err != nil {
		log.Printf("Failed to get status: %v", err)
		return false, fmt.Sprintf("Failed to get status: %v", err)
	}

	return statusResponse.Available, statusResponse.Message
}

func (c *SNMPChecker) Close() error {
	if c.service != nil {
		return c.service.Stop()
	}
	return nil
}
