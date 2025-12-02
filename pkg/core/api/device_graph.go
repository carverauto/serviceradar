package api

import (
	"encoding/json"
	"net/http"
	"strconv"

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

	queryParams := r.URL.Query()
	collectorOwnedOnly := parseBool(queryParams.Get("collector_owned"), false) ||
		parseBool(queryParams.Get("collector_owned_only"), false)
	includeTopology := parseBool(queryParams.Get("include_topology"), true)

	rows, err := s.dbService.ExecuteQuery(
		r.Context(),
		ageDeviceNeighborhoodQuery,
		deviceID,
		collectorOwnedOnly,
		includeTopology,
	)
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

func parseBool(raw string, defaultValue bool) bool {
	if raw == "" {
		return defaultValue
	}
	val, err := strconv.ParseBool(raw)
	if err != nil {
		return defaultValue
	}
	return val
}

const ageDeviceNeighborhoodQuery = `
SELECT public.age_device_neighborhood($1::text, $2::boolean, $3::boolean) AS result;
`
