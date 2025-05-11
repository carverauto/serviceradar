package models

// ColumnKey represents a column in the schema
type ColumnKey int

const (
	ColumnTimestamp ColumnKey = iota + 1
	ColumnSrcAddr
	ColumnDstAddr
	ColumnSrcPort
	ColumnDstPort
	ColumnProtocol
	ColumnBytes
	ColumnPackets
	ColumnForwardingStatus
	ColumnNextHop
	ColumnSamplerAddress
	ColumnSrcAS
	ColumnDstAS
	ColumnIPTos
	ColumnVlanID
	ColumnBGPNextHop
	ColumnPacketSize
	ColumnSrcVlan
	ColumnDstVlan
	ColumnInIfName
	ColumnOutIfName
	ColumnInIfDescription
	ColumnOutIfDescription
	ColumnInIfSpeed
	ColumnOutIfSpeed
	ColumnExporterAddress
	ColumnExporterName
	ColumnMetadata
)

// ColumnDefinition represents a column in the netflow_metrics stream
type ColumnDefinition struct {
	Key       ColumnKey
	Name      string
	Type      string
	Codec     string
	Alias     string
	Default   string
	Mandatory bool
}

// ColumnDefinitions is the list of all possible columns for netflow_metrics
var ColumnDefinitions = []ColumnDefinition{
	{Key: ColumnTimestamp, Name: "timestamp", Type: "DateTime64(3)", Codec: "DoubleDelta, LZ4", Mandatory: true},
	{Key: ColumnSrcAddr, Name: "src_addr", Type: "string", Codec: "ZSTD(1)", Mandatory: true},
	{Key: ColumnDstAddr, Name: "dst_addr", Type: "string", Codec: "ZSTD(1)", Mandatory: true},
	{Key: ColumnSrcPort, Name: "src_port", Type: "uint16"},
	{Key: ColumnDstPort, Name: "dst_port", Type: "uint16"},
	{Key: ColumnProtocol, Name: "protocol", Type: "uint8"},
	{Key: ColumnBytes, Name: "bytes", Type: "uint64", Codec: "T64, LZ4", Mandatory: true},
	{Key: ColumnPackets, Name: "packets", Type: "uint64", Codec: "T64, LZ4", Mandatory: true},
	{Key: ColumnForwardingStatus, Name: "forwarding_status", Type: "uint32"},
	{Key: ColumnNextHop, Name: "next_hop", Type: "string", Codec: "ZSTD(1)"},
	{Key: ColumnSamplerAddress, Name: "sampler_address", Type: "string", Codec: "ZSTD(1)", Mandatory: true},
	{Key: ColumnSrcAS, Name: "src_as", Type: "uint32", Default: "0"},
	{Key: ColumnDstAS, Name: "dst_as", Type: "uint32", Default: "0"},
	{Key: ColumnIPTos, Name: "ip_tos", Type: "uint8"},
	{Key: ColumnVlanID, Name: "vlan_id", Type: "uint16"},
	{Key: ColumnBGPNextHop, Name: "bgp_next_hop", Type: "string", Codec: "ZSTD(1)"},
	{Key: ColumnPacketSize, Name: "packet_size", Type: "uint64", Alias: "int_div(bytes, packets)"},
	{Key: ColumnSrcVlan, Name: "src_vlan", Type: "uint16"},
	{Key: ColumnDstVlan, Name: "dst_vlan", Type: "uint16"},
	{Key: ColumnInIfName, Name: "in_if_name", Type: "LowCardinality(string)"},
	{Key: ColumnOutIfName, Name: "out_if_name", Type: "LowCardinality(string)"},
	{Key: ColumnInIfDescription, Name: "in_if_description", Type: "LowCardinality(string)"},
	{Key: ColumnOutIfDescription, Name: "out_if_description", Type: "LowCardinality(string)"},
	{Key: ColumnInIfSpeed, Name: "in_if_speed", Type: "uint32"},
	{Key: ColumnOutIfSpeed, Name: "out_if_speed", Type: "uint32"},
	{Key: ColumnExporterAddress, Name: "exporter_address", Type: "string", Codec: "ZSTD(1)"},
	{Key: ColumnExporterName, Name: "exporter_name", Type: "LowCardinality(string)"},
	{Key: ColumnMetadata, Name: "metadata", Type: "string"},
}
