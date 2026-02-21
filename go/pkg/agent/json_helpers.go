package agent

import "encoding/json"

func jsonError(msg string) json.RawMessage {
	payload, err := json.Marshal(map[string]string{"error": msg})
	if err != nil {
		return []byte(`{"error":"failed to marshal error"}`)
	}
	return payload
}
