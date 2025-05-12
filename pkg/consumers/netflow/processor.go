/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package netflow

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	flowpb "github.com/carverauto/serviceradar/proto/flow"
	"github.com/nats-io/nats.go/jetstream"
	"google.golang.org/protobuf/proto"
)

// Processor errors
var (
	ErrEmptyMessage    = errors.New("empty message received")
	ErrMessageTooShort = errors.New("message too short")
	ErrUnmarshalFlow   = errors.New("failed to unmarshal FlowMessage")
	ErrInvalidIPLength = errors.New("invalid IP address length")
	ErrCreateMetric    = errors.New("failed to create NetFlow metric")
	ErrStoreMetric     = errors.New("failed to store NetFlow metric")
	ErrMarshalMetadata = errors.New("failed to marshal metadata")
)

// Processor handles processing of NetFlow messages.
type Processor struct {
	db     db.Service
	config *NetflowConfig
}

// NewProcessor creates a new processor with a database service and configuration.
func NewProcessor(dbService db.Service, config *NetflowConfig) *Processor {
	return &Processor{
		db:     dbService,
		config: config,
	}
}

// Process processes a single NetFlow message and stores it in the database.
func (p *Processor) Process(ctx context.Context, msg jetstream.Msg) error {
	data := msg.Data()

	var err error

	if len(data) == 0 {
		log.Printf("Empty message received on subject %s", msg.Subject())
		return ErrEmptyMessage
	}

	// Parse protobuf message
	flow, err := p.unmarshalFlowMessage(data)
	if err != nil {
		return err
	}

	// Validate IP fields
	err = validateIPFields(flow)
	if err != nil {
		return err
	}

	// Create and populate metric
	metric, err := p.createNetflowMetric(flow)
	if err != nil {
		return errors.Join(ErrCreateMetric, err)
	}

	// Store the metric
	if err := p.db.StoreNetflowMetrics(ctx, []*models.NetflowMetric{metric}); err != nil {
		log.Printf("Failed to store NetFlow metric: %v", err)

		return errors.Join(ErrStoreMetric, err)
	}

	log.Printf("Stored NetFlow: SrcAddr=%s, DstAddr=%s, Bytes=%d, Packets=%d",
		metric.SrcAddr, metric.DstAddr, flow.Bytes, flow.Packets)

	return nil
}

// unmarshalFlowMessage attempts to unmarshal the FlowMessage with multiple strategies.
func (*Processor) unmarshalFlowMessage(data []byte) (*flowpb.FlowMessage, error) {
	if len(data) <= 1 {
		return nil, ErrMessageTooShort
	}

	var flow flowpb.FlowMessage

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

		if err := proto.Unmarshal(s.data, &flow); err == nil {
			return &flow, nil
		}
	}

	return nil, ErrUnmarshalFlow
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
			return ErrInvalidIPLength
		}
	}

	return nil
}

// createNetflowMetric creates a NetflowMetric from a FlowMessage.
func (*Processor) createNetflowMetric(flow *flowpb.FlowMessage) (*models.NetflowMetric, error) {
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
		return nil, errors.Join(ErrMarshalMetadata, err)
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
		IPTos:            flow.IpTos,
		VlanID:           flow.VlanId,
		BgpNextHop:       bgpNextHop,
		Metadata:         string(metadataBytes),
	}

	// Set timestamp if time_received_ns is available
	if flow.TimeReceivedNs > 0 {
		const maxInt64 = 1<<63 - 1 // Maximum int64 value: 9,223,372,036,854,775,807
		if flow.TimeReceivedNs > maxInt64 {
			log.Printf("Warning: TimeReceivedNs (%d) exceeds max int64 value (%d), using current time",
				flow.TimeReceivedNs, maxInt64)

			metric.Timestamp = time.Now()
		} else {
			// #nosec G115 -- TimeReceivedNs is guaranteed to be within int64 range
			metric.Timestamp = time.Unix(0, int64(flow.TimeReceivedNs))
		}
	}

	return metric, nil
}
