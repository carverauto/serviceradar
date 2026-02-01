package models

import (
	"encoding/json"
	"time"
)

// OCSFNetworkActivity represents OCSF 1.7.0 network_activity class events
// Reference: https://schema.ocsf.io/1.7.0/classes/network_activity
type OCSFNetworkActivity struct {
	// OCSF Core Fields
	Time        time.Time `json:"time" db:"time"`
	ClassUID    int       `json:"class_uid" db:"class_uid"`
	CategoryUID int       `json:"category_uid" db:"category_uid"`
	ActivityID  int       `json:"activity_id" db:"activity_id"`
	TypeUID     int       `json:"type_uid" db:"type_uid"`
	SeverityID  int       `json:"severity_id" db:"severity_id"`

	// Timestamps
	StartTime *time.Time `json:"start_time,omitempty" db:"start_time"`
	EndTime   *time.Time `json:"end_time,omitempty" db:"end_time"`

	// Source Endpoint (extracted for indexing)
	SrcEndpointIP   string `json:"src_endpoint_ip,omitempty" db:"src_endpoint_ip"`
	SrcEndpointPort *int   `json:"src_endpoint_port,omitempty" db:"src_endpoint_port"`
	SrcASNumber     *int   `json:"src_as_number,omitempty" db:"src_as_number"`

	// Destination Endpoint (extracted for indexing)
	DstEndpointIP   string `json:"dst_endpoint_ip,omitempty" db:"dst_endpoint_ip"`
	DstEndpointPort *int   `json:"dst_endpoint_port,omitempty" db:"dst_endpoint_port"`
	DstASNumber     *int   `json:"dst_as_number,omitempty" db:"dst_as_number"`

	// Connection Info (extracted for filtering)
	ProtocolNum  *int   `json:"protocol_num,omitempty" db:"protocol_num"`
	ProtocolName string `json:"protocol_name,omitempty" db:"protocol_name"`
	TCPFlags     *int   `json:"tcp_flags,omitempty" db:"tcp_flags"`

	// Traffic (extracted for aggregations)
	BytesTotal   int64 `json:"bytes_total" db:"bytes_total"`
	PacketsTotal int64 `json:"packets_total" db:"packets_total"`
	BytesIn      int64 `json:"bytes_in" db:"bytes_in"`
	BytesOut     int64 `json:"bytes_out" db:"bytes_out"`

	// Observer
	SamplerAddress string `json:"sampler_address,omitempty" db:"sampler_address"`

	// Full OCSF event
	OCSFPayload json.RawMessage `json:"ocsf_payload" db:"ocsf_payload"`

	// ServiceRadar metadata
	Partition string    `json:"partition" db:"partition"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// TableName returns the table name for this model
func (OCSFNetworkActivity) TableName() string {
	return "ocsf_network_activity"
}
