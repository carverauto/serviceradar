package models

import "time"

// NetflowConfig holds the configuration for the NetFlow consumer service.
type NetflowConfig struct {
	ListenAddr     string             `json:"listen_addr"`
	NATSURL        string             `json:"nats_url"`
	NATSCredsFile  string             `json:"nats_creds_file,omitempty"`
	StreamName     string             `json:"stream_name"`
	ConsumerName   string             `json:"consumer_name"`
	Security       *SecurityConfig    `json:"security"`
	EnabledFields  []ColumnKey        `json:"enabled_fields"`
	DisabledFields []ColumnKey        `json:"disabled_fields"`
	Dictionaries   []DictionaryConfig `json:"dictionaries"`
	CNPG           *CNPGDatabase      `json:"cnpg"`
}

// NetflowMetric represents a NetFlow datapoint for the netflow_metrics stream.
type NetflowMetric struct {
	Timestamp        time.Time `json:"timestamp"`
	SrcAddr          string    `json:"src_addr"`
	DstAddr          string    `json:"dst_addr"`
	SrcPort          uint32    `json:"src_port"`
	DstPort          uint32    `json:"dst_port"`
	Protocol         uint32    `json:"protocol"`
	Bytes            uint64    `json:"bytes"`
	Packets          uint64    `json:"packets"`
	ForwardingStatus uint32    `json:"forwarding_status"`
	NextHop          string    `json:"next_hop"`
	SamplerAddress   string    `json:"sampler_address"`
	SrcAs            uint32    `json:"src_as"`
	DstAs            uint32    `json:"dst_as"`
	IPTos            uint32    `json:"ip_tos"`
	VlanID           uint32    `json:"vlan_id"`
	BgpNextHop       string    `json:"bgp_next_hop"`
	Metadata         string    `json:"metadata"`
}

// DictionaryConfig represents a custom dictionary for enrichment
type DictionaryConfig struct {
	Name       string   `json:"name"`       // e.g., "asn_dictionary"
	Source     string   `json:"source"`     // e.g., "/path/to/asn.csv"
	Keys       []string `json:"keys"`       // e.g., ["ip"]
	Attributes []string `json:"attributes"` // e.g., ["asn", "name"]
	Layout     string   `json:"layout"`     // e.g., "hashed"
}
