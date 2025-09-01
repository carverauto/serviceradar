package agent

import (
    "context"
    "encoding/json"
    "time"

    "github.com/carverauto/serviceradar/proto"
)

// GetConfig returns the agent's own configuration as JSON.
// NOTE: Requires regenerated protobufs for ConfigRequest/ConfigResponse.
func (s *Server) GetConfig(ctx context.Context, req *proto.ConfigRequest) (*proto.ConfigResponse, error) {
    // Default to agent self-config when service_name matches or is empty
    cfg := s.config
    // Marshal server config to JSON bytes
    b, _ := json.Marshal(cfg)

    // Prefer req.PollerId if provided
    pollerID := req.PollerId
    // kv_store_id is not known here; poller will set KvStoreId on forwarding

    return &proto.ConfigResponse{
        Config:      b,
        ServiceName: req.ServiceName,
        ServiceType: req.ServiceType,
        AgentId:     s.config.AgentID,
        PollerId:    pollerID,
        KvStoreId:   "",
        Timestamp:   time.Now().Unix(),
    }, nil
}

// StreamConfig streams the agent's configuration in chunks for large payloads.
// NOTE: Requires regenerated protobufs for ConfigRequest/ConfigChunk.
func (s *Server) StreamConfig(req *proto.ConfigRequest, stream proto.AgentService_StreamConfigServer) error {
    cfg := s.config
    b, _ := json.Marshal(cfg)

    // Simple one-chunk implementation; expand to chunking if needed
    chunk := &proto.ConfigChunk{
        Data:       b,
        IsFinal:    true,
        ChunkIndex: 0,
        TotalChunks: 1,
        KvStoreId:  "",
        Timestamp:  time.Now().Unix(),
    }
    return stream.Send(chunk)
}
