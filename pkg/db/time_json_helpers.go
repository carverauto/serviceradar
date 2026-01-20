package db

import (
	"encoding/json"
	"strings"
	"time"
)

func sanitizeTimestamp(ts time.Time) time.Time {
	if ts.IsZero() {
		return time.Now().UTC()
	}

	return ts.UTC()
}

func normalizeJSON(raw string) (interface{}, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}

	var tmp json.RawMessage
	if err := json.Unmarshal([]byte(raw), &tmp); err != nil {
		return nil, err
	}

	return json.RawMessage(raw), nil
}
