//go:build integration
// +build integration

// Package snmp pkg/checker/snmp/snmp_integration_test.go
package snmp

import (
	"context"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/require"
)

func TestSNMPIntegration(t *testing.T) {
	t.Log("Starting direct SNMP connection test...")

	params := &gosnmp.GoSNMP{
		Target:    "192.168.1.1",
		Port:      161,
		Community: "public",
		Version:   gosnmp.Version2c,
		Timeout:   time.Duration(10) * time.Second,
	}

	err := params.Connect()
	require.NoError(t, err, "Failed to connect with gosnmp")
	defer params.Conn.Close()

	t.Logf("Successfully connected to SNMP target %s:%d", params.Target, params.Port)

	oids := []string{".1.3.6.1.2.1.2.2.1.10.4"} // ifInOctets.4
	result, err := params.Get(oids)
	require.NoError(t, err, "SNMP Get failed")
	require.Len(t, result.Variables, 1, "Expected 1 variable")

	baselineValue := result.Variables[0]
	t.Logf("Direct SNMP Get Result - OID: %s, Type: %v, Value: %v",
		baselineValue.Name, baselineValue.Type, gosnmp.ToBigInt(baselineValue.Value))

	t.Log("\nStarting SNMP service test...")

	// Create a shorter polling interval for testing
	target := Target{
		Name:      "test-router",
		Host:      "192.168.1.1",
		Port:      161,
		Community: "public",
		Version:   Version2c,
		Interval:  Duration(5 * time.Second), // Shorter interval for testing
		Timeout:   Duration(2 * time.Second),
		Retries:   2,
		OIDs: []OIDConfig{
			{
				OID:      ".1.3.6.1.2.1.2.2.1.10.4",
				Name:     "ifInOctets_4",
				DataType: TypeCounter,
				Scale:    1.0,
			},
		},
	}

	config := &Config{
		NodeAddress: "localhost:50051",
		ListenAddr:  ":50052",
		Targets:     []Target{target},
	}

	t.Logf("Creating SNMP service with config: %+v", target)

	service, err := NewSNMPService(config)
	require.NoError(t, err, "Failed to create SNMP service")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	t.Log("Starting SNMP service...")
	err = service.Start(ctx)
	require.NoError(t, err, "Failed to start service")

	// Poll status multiple times to see if data appears
	for i := 0; i < 4; i++ {
		t.Logf("\nChecking status attempt %d...", i+1)
		time.Sleep(5 * time.Second)

		status, err := service.GetStatus(context.Background())
		require.NoError(t, err, "Failed to get status")
		require.Contains(t, status, "test-router", "Target status not found")
		// TODO: revisit this i don't think we're doing status with the SNMP service like we do the others.
		// require.True(t, status["test-router"].Available, "Target should be available")

		targetStatus := status["test-router"]
		t.Log("SNMP Service Status:")
		t.Logf("  Target: test-router")
		t.Logf("  Available: %v", targetStatus.Available)
		t.Logf("  Last Poll: %v", targetStatus.LastPoll)
		t.Logf("  Error: %v", targetStatus.Error)

		if targetStatus.OIDStatus != nil && len(targetStatus.OIDStatus) > 0 {
			t.Log("  OID Status:")
			for oidName, oidStatus := range targetStatus.OIDStatus {
				t.Logf("    %s:", oidName)
				t.Logf("      Last Value: %v", oidStatus.LastValue)
				t.Logf("      Last Update: %v", oidStatus.LastUpdate)
				t.Logf("      Error Count: %d", oidStatus.ErrorCount)
				if oidStatus.LastError != "" {
					t.Logf("      Last Error: %s", oidStatus.LastError)
				}
			}
		} else {
			t.Log("  No OID status available")
		}
	}

	t.Log("\nStopping SNMP service...")
	err = service.Stop()
	require.NoError(t, err, "Failed to stop service")
	t.Log("SNMP service stopped successfully")
}
