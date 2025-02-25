package cloud

import (
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/cloud/alerts"
	"github.com/carverauto/serviceradar/pkg/cloud/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

type Metrics struct {
	Enabled   bool `json:"enabled"`
	Retention int  `json:"retention"`
	MaxNodes  int  `json:"max_nodes"`
}

type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	GrpcAddr       string                 `json:"grpc_addr"`
	DBPath         string                 `json:"db_path"`
	AlertThreshold time.Duration          `json:"alert_threshold"`
	PollerPatterns []string               `json:"poller_patterns"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
	KnownPollers   []string               `json:"known_pollers,omitempty"`
	Metrics        Metrics                `json:"metrics"`
	SNMP           snmp.Config            `json:"snmp"`
	Security       *models.SecurityConfig `json:"security"`
}

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	db             db.Service
	alertThreshold time.Duration
	webhooks       []alerts.AlertService
	apiServer      api.Service
	ShutdownChan   chan struct{}
	pollerPatterns []string
	grpcServer     *grpc.Server
	metrics        metrics.MetricCollector
	snmpManager    snmp.SNMPManager
	config         *Config
}

// OIDStatusData represents the structure of OID status data.
type OIDStatusData struct {
	LastValue  interface{} `json:"last_value"`
	LastUpdate string      `json:"last_update"`
	ErrorCount int         `json:"error_count"`
	LastError  string      `json:"last_error,omitempty"`
}

// ServiceStatus represents the status of a monitored service.
type ServiceStatus struct {
	NodeID      string
	ServiceName string
	ServiceType string
	Available   bool
	Details     string
	Timestamp   time.Time
}
