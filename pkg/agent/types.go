package agent

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
)

type Server struct {
	proto.UnimplementedAgentServiceServer
	mu           sync.RWMutex
	checkers     map[string]checker.Checker
	checkerConfs map[string]CheckerConfig
	configDir    string
	services     []Service
	listenAddr   string
	registry     checker.Registry
	errChan      chan error
	done         chan struct{}
	config       *ServerConfig
	connections  map[string]*CheckerConnection
}
type Duration time.Duration

type SweepConfig struct {
	MaxTargets    int
	MaxGoroutines int
	BatchSize     int
	MemoryLimit   int64
	Networks      []string           `json:"networks"`
	Ports         []int              `json:"ports"`
	SweepModes    []models.SweepMode `json:"sweep_modes"`
	Interval      Duration           `json:"interval"`
	Concurrency   int                `json:"concurrency"`
	Timeout       Duration           `json:"timeout"`
}

type CheckerConfig struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Address    string          `json:"address,omitempty"`
	Port       int             `json:"port,omitempty"`
	Timeout    Duration        `json:"timeout,omitempty"`
	ListenAddr string          `json:"listen_addr,omitempty"`
	Additional json.RawMessage `json:"additional,omitempty"`
	Details    json.RawMessage `json:"details,omitempty"`
}

// ServerConfig holds the configuration for the agent server.
type ServerConfig struct {
	ListenAddr string                 `json:"listen_addr"`
	Security   *models.SecurityConfig `json:"security"`
}

type CheckerConnection struct {
	client      *grpc.Client
	serviceName string
	serviceType string
	address     string
}

type ServiceError struct {
	ServiceName string
	Err         error
}

// ICMPChecker performs ICMP checks using a pre-configured scanner.
type ICMPChecker struct {
	Host    string
	scanner scan.Scanner
}

// ICMPResponse defines the structure of the ICMP check result.
type ICMPResponse struct {
	Host         string  `json:"host"`
	ResponseTime int64   `json:"response_time"` // in nanoseconds
	PacketLoss   float64 `json:"packet_loss"`
	Available    bool    `json:"available"`
}

// UnmarshalJSON implements the json.Unmarshaler interface to allow parsing of a Duration from a JSON string or number.
func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}

	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))

		return nil
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}

		*d = Duration(tmp)

		return nil
	default:
		return errInvalidDuration
	}
}
