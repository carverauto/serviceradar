package models

// CNPGDatabase describes the Timescale/CloudNativePG connection.
type CNPGDatabase struct {
	Host               string            `json:"host"`
	Port               int               `json:"port"`
	Database           string            `json:"database"`
	Username           string            `json:"username"`
	Password           string            `json:"password" sensitive:"true"`
	ApplicationName    string            `json:"application_name,omitempty"`
	SSLMode            string            `json:"ssl_mode,omitempty"`
	CertDir            string            `json:"cert_dir,omitempty"`
	TLS                *TLSConfig        `json:"tls,omitempty"`
	MaxConnections     int32             `json:"max_connections,omitempty"`
	MinConnections     int32             `json:"min_connections,omitempty"`
	MaxConnLifetime    Duration          `json:"max_conn_lifetime,omitempty"`
	HealthCheckPeriod  Duration          `json:"health_check_period,omitempty"`
	StatementTimeout   Duration          `json:"statement_timeout,omitempty"`
	ExtraRuntimeParams map[string]string `json:"runtime_params,omitempty"`
}

type Metrics struct {
	Enabled    bool  `json:"enabled"`
	Retention  int32 `json:"retention"`
	MaxPollers int32 `json:"max_pollers"`
}

// WriteBufferConfig configures the database write buffer for performance optimization
type WriteBufferConfig struct {
	MaxSize       int      `json:"max_size"`       // Maximum buffer size before forced flush (default: 500)
	FlushInterval Duration `json:"flush_interval"` // Maximum time to wait before flushing (default: 30s)
	Enabled       bool     `json:"enabled"`        // Whether buffering is enabled (default: true)
}
