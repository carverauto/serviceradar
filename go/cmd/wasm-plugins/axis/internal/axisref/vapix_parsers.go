package axisref

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
)

// ParseKeyValueBody parses line-delimited key=value payloads commonly
// returned by classic VAPIX CGI endpoints.
//
// Adapted from goxis (MIT): pkg/vapix/VapixParsers.go.
func ParseKeyValueBody(body string) (map[string]string, error) {
	lines := strings.Split(body, "\n")
	pairs := make(map[string]string)

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid line (expected key=value): %s", line)
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		pairs[key] = value
	}

	return pairs, nil
}

// StreamProfile represents one profile parsed from streamprofile.cgi key-value output.
type StreamProfile struct {
	ID          string
	Name        string
	Description string
	Parameters  map[string]string
	RawFields   map[string]string
}

// ParseStreamProfiles parses stream profile key-value responses that include
// keys like root.StreamProfile.S0.Name / root.StreamProfile.S0.Parameters.
func ParseStreamProfiles(kv map[string]string) []StreamProfile {
	if len(kv) == 0 {
		return nil
	}

	byID := map[string]*StreamProfile{}
	for key, value := range kv {
		parts := strings.Split(key, ".")
		idx := indexOf(parts, "StreamProfile")
		if idx < 0 || idx+1 >= len(parts) {
			continue
		}

		id := strings.TrimSpace(parts[idx+1])
		if id == "" {
			continue
		}

		field := ""
		if idx+2 < len(parts) {
			field = strings.Join(parts[idx+2:], ".")
		}

		profile := byID[id]
		if profile == nil {
			profile = &StreamProfile{
				ID:         id,
				Parameters: map[string]string{},
				RawFields:  map[string]string{},
			}
			byID[id] = profile
		}

		profile.RawFields[field] = value

		switch strings.ToLower(field) {
		case "name":
			profile.Name = value
		case "description":
			profile.Description = value
		case "parameters":
			profile.Parameters = parseQueryParams(value)
		}
	}

	if len(byID) == 0 {
		return nil
	}

	ids := make([]string, 0, len(byID))
	for id := range byID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	out := make([]StreamProfile, 0, len(ids))
	for _, id := range ids {
		out = append(out, *byID[id])
	}
	return out
}

func parseQueryParams(raw string) map[string]string {
	params := map[string]string{}
	if strings.TrimSpace(raw) == "" {
		return params
	}
	vals, err := url.ParseQuery(raw)
	if err != nil {
		return params
	}
	for key, value := range vals {
		if len(value) == 0 {
			continue
		}
		params[key] = value[0]
	}
	return params
}

func indexOf(parts []string, needle string) int {
	for i, part := range parts {
		if part == needle {
			return i
		}
	}
	return -1
}
