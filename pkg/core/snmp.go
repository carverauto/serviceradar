package core

import (
	"strconv"
	"strings"
)

// parseOIDConfigName extracts the base metric name and interface index from an OID config name
func parseOIDConfigName(oidConfigName string) (baseMetricName string, parsedIfIndex int32) {
	baseMetricName = oidConfigName
	potentialIfIndexStr := ""

	if strings.Contains(oidConfigName, "_") {
		parts := strings.Split(oidConfigName, "_")
		if len(parts) > 1 {
			potentialIfIndexStr = parts[len(parts)-1]
			baseMetricName = strings.Join(parts[:len(parts)-1], "_")
		}
	} else if strings.Contains(oidConfigName, ".") { // Common for OID-like names or when index is suffix after dot
		parts := strings.Split(oidConfigName, ".")
		if len(parts) > 1 {
			// Check if the last part is purely numeric; if so, it's likely an index
			if _, err := strconv.Atoi(parts[len(parts)-1]); err == nil {
				potentialIfIndexStr = parts[len(parts)-1]
				baseMetricName = strings.Join(parts[:len(parts)-1], ".")
			}
		}
	}

	if potentialIfIndexStr != "" {
		parsed, err := strconv.ParseInt(potentialIfIndexStr, 10, 32)
		if err == nil {
			parsedIfIndex = int32(parsed)
		} else {
			// Not a parsable index, reset baseMetricName if it was changed
			baseMetricName = oidConfigName
		}
	}

	return baseMetricName, parsedIfIndex
}
