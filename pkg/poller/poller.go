// pkg/poller/poller.go
package poller

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/mfreeman451/homemon/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// Duration is a wrapper around time.Duration for JSON unmarshaling
type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}
		*d = Duration(tmp)
	default:
		return fmt.Errorf("invalid duration")
	}
	return nil
}

// Check represents a service check configuration
type Check struct {
	Type    string `json:"type"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}

// AgentConfig represents configuration for a single agent
type AgentConfig struct {
	Address string  `json:"address"`
	Checks  []Check `json:"checks"`
}

// Config represents the poller configuration
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval Duration               `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
}

// Poller represents the monitoring poller
type Poller struct {
	config      Config
	cloudClient proto.PollerServiceClient
}

func New(config Config) (*Poller, error) {
	conn, err := grpc.Dial(config.CloudAddress,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}

	return &Poller{
		config:      config,
		cloudClient: proto.NewPollerServiceClient(conn),
	}, nil
}

func (p *Poller) pollAgent(ctx context.Context, agentName string, agentConfig AgentConfig) ([]*proto.ServiceStatus, error) {
	log.Printf("Polling agent %s at %s", agentName, agentConfig.Address)

	conn, err := grpc.Dial(agentConfig.Address,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("failed to connect to agent: %w", err)
	}
	defer conn.Close()

	client := proto.NewAgentServiceClient(conn)
	statuses := make([]*proto.ServiceStatus, 0, len(agentConfig.Checks))

	// Check each configured service
	for _, check := range agentConfig.Checks {
		log.Printf("Checking %s service on agent %s", check.Type, agentName)

		status, err := client.GetStatus(ctx, &proto.StatusRequest{
			ServiceName: check.Type,
			Details:     check.Details,
			Port:        check.Port,
		})
		if err != nil {
			log.Printf("Error checking service %s on agent %s: %v",
				check.Type, agentName, err)
			statuses = append(statuses, &proto.ServiceStatus{
				ServiceName: check.Type,
				Available:   false,
				Message:     err.Error(),
			})
			continue
		}

		log.Printf("Service %s status: available=%v, message=%s",
			check.Type, status.Available, status.Message)

		statuses = append(statuses, &proto.ServiceStatus{
			ServiceName: check.Type,
			Available:   status.Available,
			Message:     status.Message,
		})
	}

	return statuses, nil
}

func (p *Poller) poll(ctx context.Context) error {
	log.Printf("Starting poll cycle...")
	allStatuses := make([]*proto.ServiceStatus, 0)

	for agentName, agentConfig := range p.config.Agents {
		statuses, err := p.pollAgent(ctx, agentName, agentConfig)
		if err != nil {
			log.Printf("Error polling agent %s: %v", agentName, err)
			continue
		}
		allStatuses = append(allStatuses, statuses...)
	}

	log.Printf("Reporting status to cloud service...")
	_, err := p.cloudClient.ReportStatus(ctx, &proto.PollerStatusRequest{
		Services:  allStatuses,
		PollerId:  p.config.PollerID,
		Timestamp: time.Now().Unix(),
	})

	if err != nil {
		return fmt.Errorf("failed to report status: %w", err)
	}

	log.Printf("Poll cycle completed successfully")
	return nil
}

// Start begins the polling loop
func (p *Poller) Start(ctx context.Context) error {
	ticker := time.NewTicker(time.Duration(p.config.PollInterval))
	defer ticker.Stop()

	log.Printf("Starting poller with interval %v", time.Duration(p.config.PollInterval))

	// Do an initial poll immediately
	if err := p.poll(ctx); err != nil {
		log.Printf("Error during initial poll: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := p.poll(ctx); err != nil {
				log.Printf("Error during poll: %v", err)
			}
		}
	}
}
