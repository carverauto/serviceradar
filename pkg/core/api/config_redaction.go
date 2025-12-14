package api

import (
	"bytes"
	"encoding/json"
	"strings"
)

const redactedConfigValuePlaceholder = "__SR_REDACTED__"

var mapperSensitiveKeys = map[string]struct{}{
	"community":        {},
	"api_key":          {},
	"auth_password":    {},
	"privacy_password": {},
}

func shouldRedactConfig(serviceName string) bool {
	return strings.EqualFold(serviceName, "mapper") || strings.EqualFold(serviceName, "snmp-checker")
}

func redactConfigBytes(serviceName string, data []byte) []byte {
	if !shouldRedactConfig(serviceName) || len(data) == 0 {
		return data
	}

	var doc any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&doc); err != nil {
		return data
	}

	redactAny(doc)
	out, err := json.Marshal(doc)
	if err != nil {
		return data
	}
	return out
}

func redactAny(v any) {
	switch t := v.(type) {
	case map[string]any:
		for k, child := range t {
			if _, ok := mapperSensitiveKeys[strings.ToLower(k)]; ok {
				if str, ok := child.(string); ok && strings.TrimSpace(str) != "" {
					t[k] = redactedConfigValuePlaceholder
					continue
				}
			}
			redactAny(child)
		}
	case []any:
		for i := range t {
			redactAny(t[i])
		}
	}
}

func restoreRedactedConfigBytes(serviceName string, previous, incoming []byte) []byte {
	if !shouldRedactConfig(serviceName) || len(incoming) == 0 || len(previous) == 0 {
		return incoming
	}

	var prevDoc any
	var nextDoc any

	prevDec := json.NewDecoder(bytes.NewReader(previous))
	prevDec.UseNumber()
	if err := prevDec.Decode(&prevDoc); err != nil {
		return incoming
	}

	nextDec := json.NewDecoder(bytes.NewReader(incoming))
	nextDec.UseNumber()
	if err := nextDec.Decode(&nextDoc); err != nil {
		return incoming
	}

	merged := restoreRedactions(prevDoc, nextDoc, "")
	out, err := json.Marshal(merged)
	if err != nil {
		return incoming
	}
	return out
}

func restoreRedactions(prev any, next any, parentKey string) any {
	switch n := next.(type) {
	case map[string]any:
		p, _ := prev.(map[string]any)
		for k, child := range n {
			lk := strings.ToLower(k)
			if _, ok := mapperSensitiveKeys[lk]; ok {
				if str, ok := child.(string); ok && str == redactedConfigValuePlaceholder {
					if p != nil {
						if pv, exists := p[k]; exists {
							n[k] = pv
							continue
						}
					}
					delete(n, k)
					continue
				}
			}
			var pv any
			if p != nil {
				pv = p[k]
			}
			n[k] = restoreRedactions(pv, child, lk)
		}
		return n

	case []any:
		prevSlice, _ := prev.([]any)

		switch strings.ToLower(parentKey) {
		case "scheduled_jobs":
			prevByName := make(map[string]any, len(prevSlice))
			for _, item := range prevSlice {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				name, _ := m["name"].(string)
				name = strings.TrimSpace(name)
				if name == "" {
					continue
				}
				prevByName[name] = item
			}
			for i := range n {
				m, ok := n[i].(map[string]any)
				if !ok {
					n[i] = restoreRedactions(nil, n[i], "")
					continue
				}
				name, _ := m["name"].(string)
				name = strings.TrimSpace(name)
				n[i] = restoreRedactions(prevByName[name], n[i], "")
			}
			return n

		case "unifi_apis":
			prevByKey := make(map[string]any, len(prevSlice))
			for _, item := range prevSlice {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				key := strings.TrimSpace(stringOrFallback(m, "name", "base_url"))
				if key == "" {
					continue
				}
				prevByKey[key] = item
			}
			for i := range n {
				m, ok := n[i].(map[string]any)
				if !ok {
					n[i] = restoreRedactions(nil, n[i], "")
					continue
				}
				key := strings.TrimSpace(stringOrFallback(m, "name", "base_url"))
				n[i] = restoreRedactions(prevByKey[key], n[i], "")
			}
			return n

		default:
			for i := range n {
				var pv any
				if i < len(prevSlice) {
					pv = prevSlice[i]
				}
				n[i] = restoreRedactions(pv, n[i], "")
			}
			return n
		}
	default:
		return next
	}
}

func stringOrFallback(m map[string]any, keys ...string) string {
	if m == nil {
		return ""
	}
	for _, k := range keys {
		if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
