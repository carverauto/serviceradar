package models

type SourceConfig struct {
	Type        string            `json:"type"`        // "armis", "netbox", etc.
	Endpoint    string            `json:"endpoint"`    // API endpoint
	Credentials map[string]string `json:"credentials"` // e.g., {"api_key": "xyz"}
	Prefix      string            `json:"prefix"`      // KV key prefix, e.g., "armis/"
}
