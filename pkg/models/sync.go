package models

type SourceConfig struct {
	Type               string            `json:"type"`                 // "armis", "netbox", etc.
	Endpoint           string            `json:"endpoint"`             // API endpoint
	Credentials        map[string]string `json:"credentials"`          // e.g., {"api_key": "xyz"}
	Prefix             string            `json:"prefix"`               // KV key prefix, e.g., "armis/"
	InsecureSkipVerify bool              `json:"insecure_skip_verify"` // For TLS connections
	Queries            []QueryConfig     `json:"queries"`              // List of AQL/ASQ queries
}

// QueryConfig represents a single labeled AQL/ASQ query.
type QueryConfig struct {
	Label string `json:"label"` // Name or description of the query
	Query string `json:"query"` // The AQL/ASQ query string
}
