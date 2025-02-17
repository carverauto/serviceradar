package cloud

import (
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/checker/snmp"
	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/pkg/db"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/metrics"
	"github.com/mfreeman451/serviceradar/proto"
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
	Security       *grpc.SecurityConfig   `json:"security"`
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
