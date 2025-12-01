package api

import (
	"encoding/json"
	"net/http"

	"github.com/gorilla/mux"
)

type graphNeighborhoodResponse struct {
	RawResult interface{} `json:"result"`
}

// handleDeviceGraph returns the graph neighborhood (collectors/services/interfaces/targets) for a device.
func (s *APIServer) handleDeviceGraph(w http.ResponseWriter, r *http.Request) {
	if s.dbService == nil {
		writeError(w, "CNPG not configured", http.StatusServiceUnavailable)
		return
	}

	deviceID := mux.Vars(r)["id"]
	if deviceID == "" {
		writeError(w, "device id required", http.StatusBadRequest)
		return
	}

	rows, err := s.dbService.ExecuteQuery(r.Context(), deviceNeighborhoodQuery, deviceID)
	if err != nil {
		writeError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var result interface{}
	if len(rows) > 0 {
		// The cypher result comes back as a single column named "result".
		if val, ok := rows[0]["result"]; ok {
			result = val
		}
	}

	resp := graphNeighborhoodResponse{RawResult: result}
	body, err := json.Marshal(resp)
	if err != nil {
		writeError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

const deviceNeighborhoodQuery = `
SELECT *
FROM cypher('serviceradar', $$
    MATCH (d:Device {id: $id})
    OPTIONAL MATCH (d)-[:REPORTED_BY]->(c:Collector)
    OPTIONAL MATCH (c)-[:HOSTS_SERVICE]->(svc:Service)
    OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
    OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
    RETURN jsonb_build_object(
        'device', d,
        'collectors', collect(DISTINCT c),
        'services', collect(DISTINCT svc),
        'targets', collect(DISTINCT t),
        'interfaces', collect(DISTINCT iface)
    ) AS result
$$, jsonb_build_object('id', $1)) AS (result agtype);
`
