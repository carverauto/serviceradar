package models

type ProtonSettings struct {
	MaxExecutionTime                    int `json:"max_execution_time"`
	OutputFormatJSONQuote64bitInt       int `json:"output_format_json_quote_64bit_int"`
	AllowExperimentalLiveViews          int `json:"allow_experimental_live_views"`
	IdleConnectionTimeout               int `json:"idle_connection_timeout"`
	JoinUseNulls                        int `json:"join_use_nulls"`
	InputFormatDefaultsForOmittedFields int `json:"input_format_defaults_for_omitted_fields"`
}

type ProtonDatabase struct {
	Addresses []string       `json:"addresses"`
	Name      string         `json:"name"`
	Username  string         `json:"username"`
	Password  string         `json:"password" sensitive:"true"`
	MaxConns  int            `json:"max_conns"`
	IdleConns int            `json:"idle_conns"`
	TLS       *TLSConfig     `json:"tls,omitempty"`
	Settings  ProtonSettings `json:"settings"`
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
