package models

import "time"

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
	IpTos            uint32    `json:"ip_tos"`
	VlanId           uint32    `json:"vlan_id"`
	BgpNextHop       string    `json:"bgp_next_hop"`
	Metadata         string    `json:"metadata"`
}
