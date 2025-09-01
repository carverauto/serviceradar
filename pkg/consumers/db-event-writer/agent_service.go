package dbeventwriter

import (
    "context"
    "encoding/json"
    "time"

    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/proto"
)

// AgentService implements monitoring.AgentService for the db-event-writer.
type AgentService struct {
	proto.UnimplementedAgentServiceServer
	svc    *Service
	logger logger.Logger
}

// NewAgentService creates a new AgentService.
func NewAgentService(svc *Service) *AgentService {
	return &AgentService{svc: svc, logger: svc.logger}
}

// GetStatus responds with the operational status of the service.
func (s *AgentService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.logger.Debug().
		Str("service_name", req.ServiceName).
		Str("service_type", req.ServiceType).
		Msg("GetStatus called")

	available := s.svc != nil && s.svc.nc != nil && s.svc.db != nil

	msg := map[string]interface{}{
		"status":  "unavailable",
		"message": "db-event-writer is not operational",
	}

	if available {
		msg["status"] = "operational"
		msg["message"] = "db-event-writer is operational"
	}

	data, err := json.Marshal(msg)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal status message")
		return nil, err
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     data,
		ServiceName: "db-event-writer",
		ServiceType: "service-instance",
		AgentId:     "db-event-writer-monitor",
	}, nil
}

// GetResults implements the AgentService GetResults method.
// DB event writer service doesn't support GetResults, so return a "not supported" response.
func (s *AgentService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Debug().
		Str("service_name", req.ServiceName).
		Str("service_type", req.ServiceType).
		Msg("GetResults called - not supported")

	return &proto.ResultsResponse{
		Available:   false,
		Data:        []byte(`{"error": "GetResults not supported by db-event-writer service"}`),
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     "db-event-writer-monitor",
		PollerId:    req.PollerId,
		Timestamp:   time.Now().Unix(),
	}, nil
}

// GetConfig returns the DB event writer configuration as JSON for admin/config ingestion.
func (s *AgentService) GetConfig(_ context.Context, req *proto.ConfigRequest) (*proto.ConfigResponse, error) {
    cfg := s.svc.cfg
    var cfgBytes []byte
    var err error
    if cfg != nil {
        cfgBytes, err = json.Marshal(cfg)
        if err != nil {
            s.logger.Error().Err(err).Msg("Failed to marshal db-event-writer config")
            return nil, err
        }
    } else {
        cfgBytes = []byte("{}")
    }

    return &proto.ConfigResponse{
        Config:      cfgBytes,
        ServiceName: req.ServiceName,
        ServiceType: req.ServiceType,
        AgentId:     "db-event-writer-monitor",
        PollerId:    req.PollerId,
        KvStoreId:   "",
        Timestamp:   time.Now().Unix(),
    }, nil
}

// StreamConfig streams the DB event writer configuration (single chunk).
func (s *AgentService) StreamConfig(req *proto.ConfigRequest, stream proto.AgentService_StreamConfigServer) error {
    resp, err := s.GetConfig(stream.Context(), req)
    if err != nil {
        return err
    }
    return stream.Send(&proto.ConfigChunk{
        Data:        resp.Config,
        IsFinal:     true,
        ChunkIndex:  0,
        TotalChunks: 1,
        KvStoreId:   resp.KvStoreId,
        Timestamp:   resp.Timestamp,
    })
}
