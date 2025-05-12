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
	flowpb "github.com/carverauto/serviceradar/proto/flow"
	"github.com/nats-io/nats.go/jetstream"
	"google.golang.org/protobuf/proto"
)

// Processor handles processing of NetFlow messages.
type Processor struct {
	db     db.Service
	config NetflowConfig
}

// NewProcessor creates a new processor with a database service and configuration.
func NewProcessor(dbService db.Service, config NetflowConfig) *Processor {
	return &Processor{
		db:     dbService,
		config: config,
	}
}

// Process processes a single NetFlow message and stores it in the database.
func (p *Processor) Process(ctx context.Context, msg jetstream.Msg) error {
	data := msg.Data()

	if len(data) == 0 {
		log.Printf("Empty message received on subject %s", msg.Subject())
		return fmt.Errorf("empty message received")
	}

	// Parse protobuf message
	flow, err := p.unmarshalFlowMessage(data)
	if err != nil {
		return err
	}

	// Validate IP fields
	if err := validateIPFields(flow); err != nil {
		return err
	}

	// Create and populate metric
	metric, err := p.createNetflowMetric(flow)
	if err != nil {
		return fmt.Errorf("failed to create NetFlow metric: %w", err)
	}

	// Store the metric
	if err := p.db.StoreNetflowMetrics(ctx, []*models.NetflowMetric{metric}); err != nil {
		log.Printf("Failed to store NetFlow metric: %v", err)
		return fmt.Errorf("failed to store NetFlow metric: %w", err)
	}

	log.Printf("Stored NetFlow: SrcAddr=%s, DstAddr=%s, Bytes=%d, Packets=%d",
		metric.SrcAddr, metric.DstAddr, flow.Bytes, flow.Packets)

	return nil
}

// unmarshalFlowMessage attempts to unmarshal the FlowMessage with multiple strategies.
func (p *Processor) unmarshalFlowMessage(data []byte) (*flowpb.FlowMessage, error) {
	if len(data) <= 1 {
		return nil, fmt.Errorf("message too short")
	}

	var flow flowpb.FlowMessage

	var err error

	// Try unmarshaling strategies
	strategies := []struct {
		name string
		data []byte
		skip int
	}{
		{"direct", data, 0},
		{"skip 1 byte", data[1:], 1},
		{"skip 2 bytes", data[2:], 2},
		{"skip 3 bytes", data[3:], 3},
		{"skip 4 bytes", data[4:], 4},
	}

	for _, s := range strategies {
		if len(s.data) == 0 {
			continue
		}

		if err = proto.Unmarshal(s.data, &flow); err == nil {
			return &flow, nil
		}
	}

	return nil, fmt.Errorf("failed to unmarshal FlowMessage: %w", err)
}

// validateIPFields checks the validity of IP address fields in the FlowMessage.
func validateIPFields(flow *flowpb.FlowMessage) error {
	ipFields := []struct {
		name       string
		addr       []byte
		allowEmpty bool
	}{
		{"SrcAddr", flow.SrcAddr, false},
		{"DstAddr", flow.DstAddr, false},
		{"SamplerAddress", flow.SamplerAddress, false},
		{"NextHop", flow.NextHop, true},
		{"BgpNextHop", flow.BgpNextHop, true},
	}

	for _, field := range ipFields {
		if len(field.addr) == 0 && field.allowEmpty {
			continue
		}

		if len(field.addr) != 4 && len(field.addr) != 16 {
			log.Printf("Invalid %s length: %d", field.name, len(field.addr))
			return fmt.Errorf("invalid %s length: %d", field.name, len(field.addr))
		}
	}

	return nil
}

// createNetflowMetric creates a NetflowMetric from a FlowMessage.
func (p *Processor) createNetflowMetric(flow *flowpb.FlowMessage) (*models.NetflowMetric, error) {
	// Convert IP fields to strings
	srcAddr := net.IP(flow.SrcAddr).String()
	dstAddr := net.IP(flow.DstAddr).String()
	samplerAddress := net.IP(flow.SamplerAddress).String()
	nextHop := ""
	if len(flow.NextHop) > 0 {
		nextHop = net.IP(flow.NextHop).String()
	}
	bgpNextHop := ""
	if len(flow.BgpNextHop) > 0 {
		bgpNextHop = net.IP(flow.BgpNextHop).String()
	}

	// Create metadata map
	metadataMap := map[string]interface{}{
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
		"tcp_flags":                     flow.TcpFlags,
		"icmp_type":                     flow.IcmpType,
		"icmp_code":                     flow.IcmpCode,
	}

	metadataBytes, err := json.Marshal(metadataMap)
	if err != nil {
		log.Printf("Failed to marshal metadata: %v", err)
		return nil, fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Create metric
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

	// Set timestamp if time_received_ns is available
	if flow.TimeReceivedNs > 0 {
		metric.Timestamp = time.Unix(0, int64(flow.TimeReceivedNs))
	}

	return metric, nil
}
