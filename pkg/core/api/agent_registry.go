package api

import (
	"net/http"

	"github.com/gorilla/mux"
)

// agentInfoView represents an agent and its associated gateway information for API responses.
type agentInfoView struct {
	AgentID      string   `json:"agent_id"`
	GatewayID     string   `json:"gateway_id"`
	LastSeen     string   `json:"last_seen"`
	ServiceTypes []string `json:"service_types,omitempty"`
}

// handleListAgents retrieves all agents with their associated gateways.
// GET /api/admin/agents
func (s *APIServer) handleListAgents(w http.ResponseWriter, r *http.Request) {
	agents, err := s.dbService.ListAgentsWithGateways(r.Context())
	if err != nil {
		s.logger.Error().
			Err(err).
			Msg("Failed to list agents")
		writeError(w, "failed to list agents", http.StatusInternalServerError)
		return
	}

	views := make([]agentInfoView, 0, len(agents))
	for _, agent := range agents {
		views = append(views, agentInfoView{
			AgentID:      agent.AgentID,
			GatewayID:     agent.GatewayID,
			LastSeen:     agent.LastSeen.Format("2006-01-02T15:04:05Z07:00"),
			ServiceTypes: agent.ServiceTypes,
		})
	}

	s.writeJSON(w, http.StatusOK, views)
}

// handleListAgentsByGateway retrieves all agents associated with a specific gateway.
// GET /api/admin/gateways/{gateway_id}/agents
func (s *APIServer) handleListAgentsByGateway(w http.ResponseWriter, r *http.Request) {
	gatewayID := mux.Vars(r)["gateway_id"]
	if gatewayID == "" {
		writeError(w, "gateway_id is required", http.StatusBadRequest)
		return
	}

	agents, err := s.dbService.ListAgentsByGateway(r.Context(), gatewayID)
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("gateway_id", gatewayID).
			Msg("Failed to list agents for gateway")
		writeError(w, "failed to list agents for gateway", http.StatusInternalServerError)
		return
	}

	views := make([]agentInfoView, 0, len(agents))
	for _, agent := range agents {
		views = append(views, agentInfoView{
			AgentID:      agent.AgentID,
			GatewayID:     agent.GatewayID,
			LastSeen:     agent.LastSeen.Format("2006-01-02T15:04:05Z07:00"),
			ServiceTypes: agent.ServiceTypes,
		})
	}

	s.writeJSON(w, http.StatusOK, views)
}
