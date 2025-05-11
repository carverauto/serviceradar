package netflow

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/nats-io/nats.go/jetstream"
	flowpb "github.com/netsampler/goflow2/v2/pb"
	"google.golang.org/protobuf/proto"
)

// Processor handles processing of NetFlow messages.
type Processor struct {
	db     db.Service
	config Config
}

// NewProcessor creates a new processor with a database service and configuration.
func NewProcessor(dbService db.Service, config Config) *Processor {
	return &Processor{
		db:     dbService,
		config: config,
	}
}

// Process processes a single NetFlow message and stores it in the database.
func (p *Processor) Process(msg jetstream.Msg) error {
	// Parse protobuf message
	var flow flowpb.FlowMessage

	if err := proto.Unmarshal(msg.Data(), &flow); err != nil {
		return fmt.Errorf("failed to unmarshal FlowMessage: %w", err)
	}

	// Convert addresses
	srcAddr := net.IP(flow.SrcAddr).String()
	dstAddr := net.IP(flow.DstAddr).String()
	nextHop := net.IP(flow.NextHop).String()
	samplerAddress := net.IP(flow.SamplerAddress).String()
	bgpNextHop := net.IP(flow.BgpNextHop).String()

	// Create metadata for additional and optional fields
	metadata := map[string]interface{}{
		"type":                          flow.Type.String(),
		"sequence_num":                  flow.SequenceNum,
		"sampling_rate":                 flow.SamplingRate,
		"time_flow_start_ns":            flow.TimeFlowStartNs,
		"time_flow_end_ns":              flow.TimeFlowEndNs,
		"etype":                         flow.Etype,
		"in_if":                         flow.InIf,
		"out_if":                        flow.OutIf,
		"src_mac":                       flow.SrcMac,
		"dst_mac":                       flow.DstMac,
		"src_vlan":                      flow.SrcVlan,
		"dst_vlan":                      flow.DstVlan,
		"ip_ttl":                        flow.IpTtl,
		"ip_flags":                      flow.IpFlags,
		"ipv6_flow_label":               flow.Ipv6FlowLabel,
		"fragment_id":                   flow.FragmentId,
		"fragment_offset":               flow.FragmentOffset,
		"next_hop_as":                   flow.NextHopAs,
		"src_net":                       flow.SrcNet,
		"dst_net":                       flow.DstNet,
		"bgp_communities":               flow.BgpCommunities,
		"as_path":                       flow.AsPath,
		"mpls_ttl":                      flow.MplsTtl,
		"mpls_label":                    flow.MplsLabel,
		"mpls_ip":                       flow.MplsIp,
		"observation_domain_id":         flow.ObservationDomainId,
		"observation_point_id":          flow.ObservationPointId,
		"layer_stack":                   flow.LayerStack,
		"layer_size":                    flow.LayerSize,
		"ipv6_routing_header_addresses": flow.Ipv6RoutingHeaderAddresses,
		"ipv6_routing_header_seg_left":  flow.Ipv6RoutingHeaderSegLeft,
	}

	// Include optional fields in metadata if enabled
	if contains(p.config.EnabledFields, "tcp_flags") {
		metadata["tcp_flags"] = flow.TcpFlags
	}
	if contains(p.config.EnabledFields, "icmp") {
		metadata["icmp_type"] = flow.IcmpType
		metadata["icmp_code"] = flow.IcmpCode
	}

	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		log.Printf("Failed to marshal metadata: %v", err)
	}

	// Create NetFlow metric
	metric := &models.NetflowMetric{
		Timestamp:        time.Now(),
		SrcAddr:          srcAddr,
		DstAddr:          dstAddr,
		SrcPort:          flow.SrcPort,
		DstPort:          flow.DstPort,
		Protocol:         flow.Proto,
		Bytes:            flow.Bytes,
		Packets:          flow.Packets,
		ForwardingStatus: flow.ForwardingStatus,
		NextHop:          nextHop,
		SamplerAddress:   samplerAddress,
		SrcAs:            flow.SrcAs,
		DstAs:            flow.DstAs,
		IpTos:            flow.IpTos,
		VlanId:           flow.VlanId,
		BgpNextHop:       bgpNextHop,
		Metadata:         string(metadataBytes),
	}

	// Use time_received_ns if available
	if flow.TimeReceivedNs > 0 {
		metric.Timestamp = time.Unix(0, int64(flow.TimeReceivedNs))
	}

	// Store the metric
	if err := p.db.StoreNetflowMetrics(context.Background(), []*models.NetflowMetric{metric}); err != nil {
		return fmt.Errorf("failed to store NetFlow metric: %w", err)
	}

	log.Printf("Stored NetFlow: SrcAddr=%s, DstAddr=%s, Bytes=%d, Packets=%d",
		srcAddr, dstAddr, flow.Bytes, flow.Packets)

	return nil
}

// contains checks if a slice contains a specific string.
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}

	return false
}
