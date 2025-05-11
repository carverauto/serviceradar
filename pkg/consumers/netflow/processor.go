// processor.go
package netflow

import (
	"context"
	"encoding/hex"
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

// analyzeProtobufFormat analyzes the binary data to determine its format
func analyzeProtobufFormat(data []byte) (bool, int) {
	// Check if this might be a protobuf message
	// Protocol buffer messages typically start with a field number (tag) and wire type
	// First byte interpretation: (field_number << 3) | wire_type
	if len(data) < 1 {
		return false, 0
	}

	firstByte := data[0]
	// Extract the wire type (lower 3 bits)
	wireType := firstByte & 0x07
	// Extract the field number
	fieldNum := firstByte >> 3

	// Sanity check for a likely protobuf message:
	// Wire types 0-5 are valid in protobuf
	// Field numbers should typically be small values for first fields
	if wireType <= 5 && fieldNum > 0 && fieldNum < 20 {
		// This looks like a valid protobuf message
		// First field is likely the 'type' field
		return true, int(wireType)
	}

	return false, 0
}

// Process processes a single NetFlow message and stores it in the database.
func (p *Processor) Process(ctx context.Context, msg jetstream.Msg) error {
	data := msg.Data()
	log.Printf("Raw message data (hex): %s", hex.EncodeToString(data))
	if len(data) == 0 {
		log.Printf("Empty message received on subject %s", msg.Subject())
		return fmt.Errorf("empty message received")
	}

	metadata, _ := msg.Metadata()
	log.Printf("Processing seq=%d, subject=%s", metadata.Sequence.Stream, msg.Subject())

	// Log message length and first few bytes
	firstBytes := data
	if len(data) > 10 {
		firstBytes = data[:10]
	}
	log.Printf("Message length: %d, first 10 bytes: %x", len(data), firstBytes)

	// Parse protobuf message
	var flow flowpb.FlowMessage

	// Analyze the binary format
	isLikelyProtobuf, wireType := analyzeProtobufFormat(data)

	if isLikelyProtobuf {
		log.Printf("Data appears to be a raw protobuf message (wireType=%d), attempting direct unmarshal", wireType)
		// Try direct unmarshal first
		if err := proto.Unmarshal(data, &flow); err == nil {
			log.Printf("Successfully unmarshaled as raw protobuf")
		} else {
			log.Printf("Raw unmarshal failed: %v", err)
			log.Printf("Raw message data (first 100 bytes as string): %s", string(data[:min(100, len(data))]))
			log.Printf("Full raw data (hex): %s", hex.EncodeToString(data))
			return fmt.Errorf("failed to unmarshal FlowMessage: %w", err)
		}
	} else {
		// This doesn't look like a standard protobuf - try a different approach
		log.Printf("Data format doesn't look like standard protobuf, trying different approaches")

		// Try removing the first byte (which might be a length indicator)
		if len(data) > 1 {
			firstByte := data[0]
			log.Printf("First byte: 0x%02x (%d)", firstByte, firstByte)

			// Try direct unmarshal without the first byte
			if err := proto.Unmarshal(data[1:], &flow); err == nil {
				log.Printf("Successfully unmarshaled after skipping first byte")
			} else {
				// As a last resort, try the original data
				if err := proto.Unmarshal(data, &flow); err != nil {
					log.Printf("All unmarshal attempts failed: %v", err)
					log.Printf("Raw message data (first 100 bytes as string): %s", string(data[:min(100, len(data))]))
					log.Printf("Full raw data (hex): %s", hex.EncodeToString(data))
					return fmt.Errorf("failed to unmarshal FlowMessage: %w", err)
				}
			}
		} else {
			return fmt.Errorf("message too short")
		}
	}

	// Validate IP fields
	if len(flow.SrcAddr) != 4 && len(flow.SrcAddr) != 16 {
		log.Printf("Invalid SrcAddr length: %d", len(flow.SrcAddr))
		return fmt.Errorf("invalid SrcAddr length: %d", len(flow.SrcAddr))
	}
	if len(flow.DstAddr) != 4 && len(flow.DstAddr) != 16 {
		log.Printf("Invalid DstAddr length: %d", len(flow.DstAddr))
		return fmt.Errorf("invalid DstAddr length: %d", len(flow.DstAddr))
	}
	if len(flow.SamplerAddress) != 4 && len(flow.SamplerAddress) != 16 {
		log.Printf("Invalid SamplerAddress length: %d", len(flow.SamplerAddress))
		return fmt.Errorf("invalid SamplerAddress length: %d", len(flow.SamplerAddress))
	}
	// NextHop and BgpNextHop are optional, allow empty
	if len(flow.NextHop) > 0 && len(flow.NextHop) != 4 && len(flow.NextHop) != 16 {
		log.Printf("Invalid NextHop length: %d", len(flow.NextHop))
		return fmt.Errorf("invalid NextHop length: %d", len(flow.NextHop))
	}
	if len(flow.BgpNextHop) > 0 && len(flow.BgpNextHop) != 4 && len(flow.BgpNextHop) != 16 {
		log.Printf("Invalid BgpNextHop length: %d", len(flow.BgpNextHop))
		return fmt.Errorf("invalid BgpNextHop length: %d", len(flow.BgpNextHop))
	}

	// Convert IP fields to strings
	srcAddr := net.IP(flow.SrcAddr).String()
	dstAddr := net.IP(flow.DstAddr).String()
	nextHop := ""
	if len(flow.NextHop) > 0 {
		nextHop = net.IP(flow.NextHop).String()
	}
	samplerAddress := net.IP(flow.SamplerAddress).String()
	bgpNextHop := ""
	if len(flow.BgpNextHop) > 0 {
		bgpNextHop = net.IP(flow.BgpNextHop).String()
	}

	// Create metadata for additional fields
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
	if err := p.db.StoreNetflowMetrics(ctx, []*models.NetflowMetric{metric}); err != nil {
		log.Printf("Failed to store NetFlow metric: %v", err)
		return fmt.Errorf("failed to store NetFlow metric: %w", err)
	}

	log.Printf("Stored NetFlow: SrcAddr=%s, DstAddr=%s, Bytes=%d, Packets=%d",
		metric.SrcAddr, metric.DstAddr, flow.Bytes, flow.Packets)

	return nil
}
