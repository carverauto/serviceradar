package trivysidecar

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultNATSSubjectPrefix   = "trivy.report"
	defaultNATSStreamName      = "trivy_reports"
	defaultMetricsAddr         = ":9108"
	defaultReportGroupVersion  = "aquasecurity.github.io/v1alpha1"
	defaultPublishTimeout      = 5 * time.Second
	defaultPublishMaxRetries   = 5
	defaultPublishRetryDelay   = 500 * time.Millisecond
	defaultInformerResync      = 5 * time.Minute
	defaultPublishRetryMaxBack = 10 * time.Second
)

var (
	errNATSURLRequired           = errors.New("NATS_HOSTPORT is required")
	errClusterIDRequired         = errors.New("CLUSTER_ID is required")
	errPublishRetryNegative      = errors.New("TRIVY_PUBLISH_MAX_RETRIES must be >= 0")
	errPublishTimeoutNonPositive = errors.New("TRIVY_PUBLISH_TIMEOUT must be > 0")
	errRetryDelayNonPositive     = errors.New("TRIVY_PUBLISH_RETRY_DELAY must be > 0")
	errResyncNonPositive         = errors.New("TRIVY_INFORMER_RESYNC must be > 0")
)

// Config contains runtime settings for Trivy report publishing.
type Config struct {
	NATSHostPort      string
	NATSSubjectPrefix string
	NATSStreamName    string
	NATSCredsFile     string
	NATSCACertFile    string
	NATSCertFile      string
	NATSKeyFile       string
	NATSServerName    string
	NATSSkipVerify    bool

	KubeConfigPath     string
	ClusterID          string
	ReportGroupVersion string

	MetricsAddr          string
	InformerResync       time.Duration
	PublishTimeout       time.Duration
	PublishMaxRetries    int
	PublishRetryDelay    time.Duration
	PublishRetryMaxDelay time.Duration
}

// LoadConfigFromEnv reads sidecar settings from environment variables.
func LoadConfigFromEnv() (Config, error) {
	cfg := Config{
		NATSHostPort:         strings.TrimSpace(os.Getenv("NATS_HOSTPORT")),
		NATSSubjectPrefix:    strings.TrimSpace(os.Getenv("NATS_SUBJECT_PREFIX")),
		NATSStreamName:       strings.TrimSpace(os.Getenv("NATS_STREAM")),
		NATSCredsFile:        strings.TrimSpace(os.Getenv("NATS_CREDSFILE")),
		NATSCACertFile:       strings.TrimSpace(os.Getenv("NATS_CACERTFILE")),
		NATSCertFile:         strings.TrimSpace(os.Getenv("NATS_CERTFILE")),
		NATSKeyFile:          strings.TrimSpace(os.Getenv("NATS_KEYFILE")),
		NATSServerName:       strings.TrimSpace(os.Getenv("NATS_SERVER_NAME")),
		KubeConfigPath:       strings.TrimSpace(os.Getenv("KUBECONFIG")),
		ClusterID:            strings.TrimSpace(os.Getenv("CLUSTER_ID")),
		ReportGroupVersion:   strings.TrimSpace(os.Getenv("TRIVY_REPORT_GROUP_VERSION")),
		MetricsAddr:          strings.TrimSpace(os.Getenv("TRIVY_METRICS_ADDR")),
		NATSSkipVerify:       parseBoolEnv("NATS_SKIP_TLS_VERIFY", false),
		PublishMaxRetries:    defaultPublishMaxRetries,
		PublishTimeout:       defaultPublishTimeout,
		PublishRetryDelay:    defaultPublishRetryDelay,
		PublishRetryMaxDelay: defaultPublishRetryMaxBack,
		InformerResync:       defaultInformerResync,
	}

	if cfg.NATSSubjectPrefix == "" {
		cfg.NATSSubjectPrefix = defaultNATSSubjectPrefix
	}

	if cfg.NATSStreamName == "" {
		cfg.NATSStreamName = defaultNATSStreamName
	}

	if cfg.ReportGroupVersion == "" {
		cfg.ReportGroupVersion = defaultReportGroupVersion
	}

	if cfg.MetricsAddr == "" {
		cfg.MetricsAddr = defaultMetricsAddr
	}

	if v := strings.TrimSpace(os.Getenv("TRIVY_PUBLISH_MAX_RETRIES")); v != "" {
		retries, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("parse TRIVY_PUBLISH_MAX_RETRIES: %w", err)
		}

		cfg.PublishMaxRetries = retries
	}

	if d, err := parseDurationEnv("TRIVY_PUBLISH_TIMEOUT"); err != nil {
		return Config{}, err
	} else if d > 0 {
		cfg.PublishTimeout = d
	}

	if d, err := parseDurationEnv("TRIVY_PUBLISH_RETRY_DELAY"); err != nil {
		return Config{}, err
	} else if d > 0 {
		cfg.PublishRetryDelay = d
	}

	if d, err := parseDurationEnv("TRIVY_PUBLISH_MAX_RETRY_DELAY"); err != nil {
		return Config{}, err
	} else if d > 0 {
		cfg.PublishRetryMaxDelay = d
	}

	if d, err := parseDurationEnv("TRIVY_INFORMER_RESYNC"); err != nil {
		return Config{}, err
	} else if d > 0 {
		cfg.InformerResync = d
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

// Validate checks configuration values.
func (c Config) Validate() error {
	if c.NATSHostPort == "" {
		return errNATSURLRequired
	}

	if c.ClusterID == "" {
		return errClusterIDRequired
	}

	if c.PublishMaxRetries < 0 {
		return errPublishRetryNegative
	}

	if c.PublishTimeout <= 0 {
		return errPublishTimeoutNonPositive
	}

	if c.PublishRetryDelay <= 0 {
		return errRetryDelayNonPositive
	}

	if c.InformerResync <= 0 {
		return errResyncNonPositive
	}

	return nil
}

func parseDurationEnv(key string) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return 0, nil
	}

	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", key, err)
	}

	return d, nil
}

func parseBoolEnv(key string, fallback bool) bool {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}

	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return fallback
	}

	return parsed
}
