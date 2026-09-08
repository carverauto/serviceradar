//go:build integration
// +build integration

/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package snmp pkg/agent/snmp/snmp_integration_test.go
package snmp

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// snmpTargetEnv names the host this suite talks to. There is no default: the address below
// was hardcoded to 192.168.1.1, a private LAN address that belongs to whoever wrote the test
// and resolves to nothing in CI or on anyone else's machine. Rather than fail for ten seconds
// against an unreachable router, the suite now skips unless the target is named explicitly.
const snmpTargetEnv = "SERVICERADAR_TEST_SNMP_TARGET"

func TestSNMPIntegration(t *testing.T) {
	targetHost := os.Getenv(snmpTargetEnv)
	if targetHost == "" {
		t.Skipf("set %s to an SNMP agent (host only, port 161 is assumed) to run this", snmpTargetEnv)
	}

	t.Log("Starting direct SNMP connection test...")

	params := &gosnmp.GoSNMP{
		Target:    targetHost,
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
		Host:      targetHost,
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

	config := &SNMPConfig{
		NodeAddress: "localhost:50051",
		ListenAddr:  ":50052",
		Targets:     []Target{target},
	}

	t.Logf("Creating SNMP service with config: %+v", target)

	service, err := NewSNMPService(config, logger.NewTestLogger())
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
