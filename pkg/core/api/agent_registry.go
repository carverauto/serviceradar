package api

import (
	"net/http"

	"github.com/gorilla/mux"
)

// agentInfoView represents an agent and its associated poller information for API responses.
type agentInfoView struct {
	AgentID      string   `json:"agent_id"`
	PollerID     string   `json:"poller_id"`
	LastSeen     string   `json:"last_seen"`
	ServiceTypes []string `json:"service_types,omitempty"`
}

// handleListAgents retrieves all agents with their associated pollers.
// GET /api/admin/agents
func (s *APIServer) handleListAgents(w http.ResponseWriter, r *http.Request) {
	agents, err := s.dbService.ListAgentsWithPollers(r.Context())
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
			PollerID:     agent.PollerID,
			LastSeen:     agent.LastSeen.Format("2006-01-02T15:04:05Z07:00"),
			ServiceTypes: agent.ServiceTypes,
		})
	}

	s.writeJSON(w, http.StatusOK, views)
}

// handleListAgentsByPoller retrieves all agents associated with a specific poller.
// GET /api/admin/pollers/{poller_id}/agents
func (s *APIServer) handleListAgentsByPoller(w http.ResponseWriter, r *http.Request) {
	pollerID := mux.Vars(r)["poller_id"]
	if pollerID == "" {
		writeError(w, "poller_id is required", http.StatusBadRequest)
		return
	}

	agents, err := s.dbService.ListAgentsByPoller(r.Context(), pollerID)
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Msg("Failed to list agents for poller")
		writeError(w, "failed to list agents for poller", http.StatusInternalServerError)
		return
	}

	views := make([]agentInfoView, 0, len(agents))
	for _, agent := range agents {
		views = append(views, agentInfoView{
			AgentID:      agent.AgentID,
			PollerID:     agent.PollerID,
			LastSeen:     agent.LastSeen.Format("2006-01-02T15:04:05Z07:00"),
			ServiceTypes: agent.ServiceTypes,
		})
	}

	s.writeJSON(w, http.StatusOK, views)
}
