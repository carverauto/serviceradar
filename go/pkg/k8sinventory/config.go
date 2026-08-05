package k8sinventory

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultNATSSubjectPrefix = "inventory.k8s.public_endpoints"
	defaultNATSStreamName    = "k8s_inventory"
	defaultMetricsAddr       = ":9109"
	defaultPublishTimeout    = 5 * time.Second
	defaultPublishMaxRetries = 5
	defaultPublishRetryDelay = 500 * time.Millisecond
	defaultPublishRetryMax   = 10 * time.Second
	defaultResync            = 5 * time.Minute
	defaultDebounce          = 2 * time.Second
	defaultPublishMode       = "nats" // nats | stdout | none
)

var (
	errClusterIDRequired     = errors.New("CLUSTER_ID is required")
	errNATSURLRequired       = errors.New("NATS_HOSTPORT is required when PUBLISH_MODE=nats")
	errInvalidPublishMode    = errors.New("PUBLISH_MODE must be nats, stdout, or none")
	errResyncNonPositive     = errors.New("K8S_INVENTORY_RESYNC must be > 0")
	errDebounceNonPositive   = errors.New("K8S_INVENTORY_DEBOUNCE must be > 0")
	errPublishTimeoutInvalid = errors.New("K8S_INVENTORY_PUBLISH_TIMEOUT must be > 0")
)

// Config is runtime configuration for the inventory collector.
type Config struct {
	ClusterID      string
	KubeConfigPath string
	Namespaces     []string // empty = all

	EnableGatewayAPI bool
	PublishMode      string // nats | stdout | none
	Subject          string // full subject for snapshot publish

	NATSHostPort   string
	NATSStreamName string
	NATSCredsFile  string
	NATSCACertFile string
	NATSCertFile   string
	NATSKeyFile    string
	NATSServerName string
	NATSSkipVerify bool

	MetricsAddr          string
	Resync               time.Duration
	Debounce             time.Duration
	PublishTimeout       time.Duration
	PublishMaxRetries    int
	PublishRetryDelay    time.Duration
	PublishRetryMaxDelay time.Duration
}

// LoadConfigFromEnv loads collector config from environment variables.
func LoadConfigFromEnv() (Config, error) {
	cfg := Config{
		ClusterID:            strings.TrimSpace(os.Getenv("CLUSTER_ID")),
		KubeConfigPath:       strings.TrimSpace(os.Getenv("KUBECONFIG")),
		EnableGatewayAPI:     parseBoolEnv("K8S_INVENTORY_GATEWAY_API", true),
		PublishMode:          strings.ToLower(strings.TrimSpace(os.Getenv("PUBLISH_MODE"))),
		Subject:              strings.TrimSpace(os.Getenv("K8S_INVENTORY_SUBJECT")),
		NATSHostPort:         strings.TrimSpace(os.Getenv("NATS_HOSTPORT")),
		NATSStreamName:       strings.TrimSpace(os.Getenv("NATS_STREAM")),
		NATSCredsFile:        strings.TrimSpace(os.Getenv("NATS_CREDSFILE")),
		NATSCACertFile:       strings.TrimSpace(os.Getenv("NATS_CACERTFILE")),
		NATSCertFile:         strings.TrimSpace(os.Getenv("NATS_CERTFILE")),
		NATSKeyFile:          strings.TrimSpace(os.Getenv("NATS_KEYFILE")),
		NATSServerName:       strings.TrimSpace(os.Getenv("NATS_SERVER_NAME")),
		NATSSkipVerify:       parseBoolEnv("NATS_SKIP_TLS_VERIFY", false),
		MetricsAddr:          strings.TrimSpace(os.Getenv("K8S_INVENTORY_METRICS_ADDR")),
		PublishMaxRetries:    defaultPublishMaxRetries,
		PublishTimeout:       defaultPublishTimeout,
		PublishRetryDelay:    defaultPublishRetryDelay,
		PublishRetryMaxDelay: defaultPublishRetryMax,
		Resync:               defaultResync,
		Debounce:             defaultDebounce,
	}

	if cfg.PublishMode == "" {
		cfg.PublishMode = defaultPublishMode
	}
	switch cfg.PublishMode {
	case "nats", "stdout", "none":
	default:
		return Config{}, errInvalidPublishMode
	}

	if cfg.Subject == "" {
		cfg.Subject = defaultNATSSubjectPrefix
	}
	if cfg.NATSStreamName == "" {
		cfg.NATSStreamName = defaultNATSStreamName
	}
	if cfg.MetricsAddr == "" {
		cfg.MetricsAddr = defaultMetricsAddr
	}

	if ns := strings.TrimSpace(os.Getenv("K8S_INVENTORY_NAMESPACES")); ns != "" {
		for _, part := range strings.Split(ns, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				cfg.Namespaces = append(cfg.Namespaces, part)
			}
		}
	}

	if v := strings.TrimSpace(os.Getenv("K8S_INVENTORY_RESYNC")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse K8S_INVENTORY_RESYNC: %w", err)
		}
		cfg.Resync = d
	}
	if v := strings.TrimSpace(os.Getenv("K8S_INVENTORY_DEBOUNCE")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse K8S_INVENTORY_DEBOUNCE: %w", err)
		}
		cfg.Debounce = d
	}
	if v := strings.TrimSpace(os.Getenv("K8S_INVENTORY_PUBLISH_TIMEOUT")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse K8S_INVENTORY_PUBLISH_TIMEOUT: %w", err)
		}
		cfg.PublishTimeout = d
	}
	if v := strings.TrimSpace(os.Getenv("K8S_INVENTORY_PUBLISH_MAX_RETRIES")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse K8S_INVENTORY_PUBLISH_MAX_RETRIES: %w", err)
		}
		cfg.PublishMaxRetries = n
	}
	if v := strings.TrimSpace(os.Getenv("K8S_INVENTORY_PUBLISH_RETRY_DELAY")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse K8S_INVENTORY_PUBLISH_RETRY_DELAY: %w", err)
		}
		cfg.PublishRetryDelay = d
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Validate checks required fields.
func (c Config) Validate() error {
	if strings.TrimSpace(c.ClusterID) == "" {
		return errClusterIDRequired
	}
	if c.Resync <= 0 {
		return errResyncNonPositive
	}
	if c.Debounce <= 0 {
		return errDebounceNonPositive
	}
	if c.PublishTimeout <= 0 {
		return errPublishTimeoutInvalid
	}
	if c.PublishMode == "nats" && strings.TrimSpace(c.NATSHostPort) == "" {
		return errNATSURLRequired
	}
	return nil
}

func parseBoolEnv(key string, def bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}
