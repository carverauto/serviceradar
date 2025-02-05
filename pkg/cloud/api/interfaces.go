package api

//go:generate mockgen -destination=mock_api_server.go -package=api github.com/mfreeman451/serviceradar/pkg/cloud/api Service

// Service represents the API server functionality.
type Service interface {
	Start(addr string) error
	UpdateNodeStatus(nodeID string, status *NodeStatus)
	SetNodeHistoryHandler(handler func(nodeID string) ([]NodeHistoryPoint, error))
	SetKnownPollers(knownPollers []string)
}
