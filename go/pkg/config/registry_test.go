package config

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestServiceDescriptorsExcludeRetiredRPerfCheckers(t *testing.T) {
	descriptors := ServiceDescriptors()
	require.NotEmpty(t, descriptors)

	names := make(map[string]struct{}, len(descriptors))
	for _, desc := range descriptors {
		names[desc.Name] = struct{}{}
		require.NotEqual(t, "rperf-checker", desc.Name)
		require.NotEqual(t, "rperf-checker", desc.ServiceType)
		require.NotEqual(t, "agent-rperf", desc.Name)
		require.NotContains(t, desc.KVKey, "rperf")
		require.NotContains(t, desc.KVKeyTemplate, "rperf")
	}

	require.Contains(t, names, "agent")
	require.Contains(t, names, "agent-snmp")
	require.Contains(t, names, "agent-trapd")
}
