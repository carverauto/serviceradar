package netflow

import (
	"fmt"
	"log"
	"net"

	"github.com/nats-io/nats.go"
	flowpb "github.com/netsampler/goflow2/v2/pb"
	"google.golang.org/protobuf/proto"
)

// Processor handles processing of NetFlow messages.
type Processor struct{}

// NewProcessor creates a new processor.
func NewProcessor() *Processor {
	return &Processor{}
}

// Process processes a single NetFlow message.
func (p *Processor) Process(msg *nats.Msg) error {
	// Parse protobuf message
	var flow flowpb.FlowMessage

	if err := proto.Unmarshal(msg.Data, &flow); err != nil {
		return fmt.Errorf("failed to unmarshal FlowMessage: %w", err)
	}

	// Convert addresses from bytes to string
	srcAddr := net.IP(flow.SrcAddr).String()
	dstAddr := net.IP(flow.DstAddr).String()

	// Log flow details (placeholder for actual processing)
	log.Printf("Processed NetFlow message on subject %s: Type=%s, SrcAddr=%s, DstAddr=%s, SrcPort=%d, DstPort=%d, Bytes=%d",
		msg.Subject, flow.Type.String(), srcAddr, dstAddr, flow.SrcPort, flow.DstPort, flow.Bytes)

	// TODO: Implement actual NetFlow processing
	// e.g., Store in database, send to analytics, etc.
	// Example:
	// storeFlowToDB(flow)
	// sendToAnalytics(flow)

	return nil
}
