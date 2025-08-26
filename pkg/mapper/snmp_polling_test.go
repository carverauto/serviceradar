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

package mapper

import (
	"math"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
)

func TestSafeInt32(t *testing.T) {
	tests := []struct {
		name     string
		input    int
		expected int32
	}{
		{
			name:     "normal value",
			input:    42,
			expected: 42,
		},
		{
			name:     "zero",
			input:    0,
			expected: 0,
		},
		{
			name:     "negative value",
			input:    -42,
			expected: -42,
		},
		{
			name:     "max int32",
			input:    math.MaxInt32,
			expected: math.MaxInt32,
		},
		{
			name:     "min int32",
			input:    math.MinInt32,
			expected: math.MinInt32,
		},
		{
			name:     "exceeds max int32",
			input:    math.MaxInt32 + 1,
			expected: math.MaxInt32,
		},
		{
			name:     "below min int32",
			input:    math.MinInt32 - 1,
			expected: math.MinInt32,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := safeInt32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGetInt32FromPDU(t *testing.T) {
	tests := []struct {
		name      string
		pdu       gosnmp.SnmpPDU
		fieldName string
		expected  int32
		ok        bool
	}{
		{
			name: "valid integer",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			fieldName: "testField",
			expected:  42,
			ok:        true,
		},
		{
			name: "zero integer",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 0,
			},
			fieldName: "testField",
			expected:  0,
			ok:        true,
		},
		{
			name: "negative integer",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: -42,
			},
			fieldName: "testField",
			expected:  -42,
			ok:        true,
		},
		{
			name: "max int32",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: math.MaxInt32,
			},
			fieldName: "testField",
			expected:  math.MaxInt32,
			ok:        true,
		},
		{
			name: "min int32",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: math.MinInt32,
			},
			fieldName: "testField",
			expected:  math.MinInt32,
			ok:        true,
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: "not an integer",
			},
			fieldName: "testField",
			expected:  0,
			ok:        false,
		},
		{
			name: "value not int",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: "42", // String instead of int
			},
			fieldName: "testField",
			expected:  0,
			ok:        false,
		},
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, ok := engine.getInt32FromPDU(tt.pdu, tt.fieldName)
			assert.Equal(t, tt.ok, ok)

			if ok {
				assert.Equal(t, tt.expected, result)
			}
		})
	}
}

func TestConvertToUint64(t *testing.T) {
	tests := []struct {
		name     string
		input    interface{}
		expected uint64
		ok       bool
	}{
		{
			name:     "uint",
			input:    uint(42),
			expected: 42,
			ok:       true,
		},
		{
			name:     "uint32",
			input:    uint32(42),
			expected: 42,
			ok:       true,
		},
		{
			name:     "uint64",
			input:    uint64(42),
			expected: 42,
			ok:       true,
		},
		{
			name:     "int positive",
			input:    42,
			expected: 42,
			ok:       true,
		},
		{
			name:     "int32 positive",
			input:    int32(42),
			expected: 42,
			ok:       true,
		},
		{
			name:     "int64 positive",
			input:    int64(42),
			expected: 42,
			ok:       true,
		},
		{
			name:     "int negative",
			input:    -42,
			expected: 0,
			ok:       false,
		},
		{
			name:     "int32 negative",
			input:    int32(-42),
			expected: 0,
			ok:       false,
		},
		{
			name:     "int64 negative",
			input:    int64(-42),
			expected: 0,
			ok:       false,
		},
		{
			name:     "string",
			input:    "42",
			expected: 0,
			ok:       false,
		},
		{
			name:     "nil",
			input:    nil,
			expected: 0,
			ok:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, ok := convertToUint64(tt.input)
			assert.Equal(t, tt.ok, ok)

			if ok {
				assert.Equal(t, tt.expected, result)
			}
		})
	}
}

func TestIsMaxUint32(t *testing.T) {
	tests := []struct {
		name     string
		input    uint64
		expected bool
	}{
		{
			name:     "max uint32",
			input:    4294967295, // 2^32 - 1
			expected: true,
		},
		{
			name:     "less than max uint32",
			input:    4294967294,
			expected: false,
		},
		{
			name:     "greater than max uint32",
			input:    4294967296,
			expected: false,
		},
		{
			name:     "zero",
			input:    0,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isMaxUint32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractSpeedFromGauge32(t *testing.T) {
	tests := []struct {
		name     string
		input    interface{}
		expected uint64
	}{
		{
			name:     "normal value",
			input:    uint32(100000000), // 100 Mbps
			expected: 100000000,
		},
		{
			name:     "zero",
			input:    uint32(0),
			expected: 0,
		},
		{
			name:     "max uint32",
			input:    uint32(4294967295), // 2^32 - 1
			expected: 0,                  // Should return 0 for max uint32 as it indicates we need to check ifHighSpeed
		},
		{
			name:     "wrong type",
			input:    "not a number",
			expected: 0,
		},
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := engine.extractSpeedFromGauge32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractSpeedFromCounter32(t *testing.T) {
	tests := []struct {
		name     string
		input    interface{}
		expected uint64
	}{
		{
			name:     "normal value",
			input:    uint32(100000000), // 100 Mbps
			expected: 100000000,
		},
		{
			name:     "zero",
			input:    uint32(0),
			expected: 0,
		},
		{
			name:     "wrong type",
			input:    "not a number",
			expected: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractSpeedFromCounter32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestUpdateIfDescr(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected string
	}{
		{
			name: "valid octet string",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte("GigabitEthernet0/1"),
			},
			expected: "GigabitEthernet0/1",
		},
		{
			name: "empty octet string",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte(""),
			},
			expected: "",
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			expected: "", // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{}
			updateIfDescr(iface, tt.pdu)
			assert.Equal(t, tt.expected, iface.IfDescr)
		})
	}
}

func TestUpdateIfType(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected int32
	}{
		{
			name: "valid integer",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 6, // ethernetCsmacd
			},
			expected: 6,
		},
		{
			name: "zero",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 0,
			},
			expected: 0,
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte("not an integer"),
			},
			expected: 0, // Should not change
		},
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{}
			engine.updateIfType(iface, tt.pdu)
			assert.Equal(t, tt.expected, iface.IfType)
		})
	}
}

func TestMatchesOIDPrefix(t *testing.T) {
	tests := []struct {
		name     string
		fullOID  string
		prefix   string
		expected bool
	}{
		{
			name:     "exact match",
			fullOID:  ".1.3.6.1.2.1.2.2.1.1",
			prefix:   ".1.3.6.1.2.1.2.2.1.1",
			expected: true,
		},
		{
			name:     "prefix match",
			fullOID:  ".1.3.6.1.2.1.2.2.1.1.1",
			prefix:   ".1.3.6.1.2.1.2.2.1.1",
			expected: true,
		},
		{
			name:     "no match",
			fullOID:  ".1.3.6.1.2.1.2.2.1.2.1",
			prefix:   ".1.3.6.1.2.1.2.2.1.1",
			expected: false,
		},
		{
			name:     "empty prefix",
			fullOID:  ".1.3.6.1.2.1.2.2.1.1.1",
			prefix:   "",
			expected: false,
		},
		{
			name:     "empty full OID",
			fullOID:  "",
			prefix:   ".1.3.6.1.2.1.2.2.1.1",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := matchesOIDPrefix(tt.fullOID, tt.prefix)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestFormatMACAddress(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected string
	}{
		{
			name:     "valid MAC",
			input:    []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
			expected: "00:11:22:33:44:55",
		},
		{
			name:     "empty MAC",
			input:    []byte{},
			expected: "",
		},
		{
			name:     "invalid length",
			input:    []byte{0x00, 0x11, 0x22, 0x33, 0x44}, // Only 5 bytes
			expected: "",
		},
		{
			name:     "all zeros",
			input:    []byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
			expected: "00:00:00:00:00:00",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := formatMACAddress(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractIPFromOID(t *testing.T) {
	tests := []struct {
		name     string
		oid      string
		expected string
		ok       bool
	}{
		{
			name:     "valid IP OID",
			oid:      ".1.3.6.1.2.1.4.20.1.1.192.168.1.1",
			expected: "192.168.1.1",
			ok:       true,
		},
		{
			name:     "invalid IP OID - too short",
			oid:      ".1.3.6.1.2.1.4.20.1.1.192.168.1",
			expected: "",
			ok:       false,
		},
		{
			name:     "invalid IP OID - not an IP",
			oid:      ".1.3.6.1.2.1.4.20.1.1.not.an.ip.address",
			expected: "",
			ok:       false,
		},
		{
			name:     "empty OID",
			oid:      "",
			expected: "",
			ok:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, ok := extractIPFromOID(tt.oid)
			assert.Equal(t, tt.ok, ok)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestProcessSNMPVariables(t *testing.T) {
	tests := []struct {
		name           string
		variables      []gosnmp.SnmpPDU
		expectedResult bool
		expectedDevice *DiscoveredDevice
	}{
		{
			name: "valid variables",
			variables: []gosnmp.SnmpPDU{
				{
					Name:  oidSysDescr,
					Type:  gosnmp.OctetString,
					Value: []byte("Test System Description"),
				},
				{
					Name:  oidSysObjectID,
					Type:  gosnmp.ObjectIdentifier,
					Value: ".1.3.6.1.4.1.9.1.1",
				},
				{
					Name:  oidSysUptime,
					Type:  gosnmp.TimeTicks,
					Value: uint32(12345),
				},
				{
					Name:  oidSysContact,
					Type:  gosnmp.OctetString,
					Value: []byte("admin@example.com"),
				},
				{
					Name:  oidSysName,
					Type:  gosnmp.OctetString,
					Value: []byte("test-device"),
				},
				{
					Name:  oidSysLocation,
					Type:  gosnmp.OctetString,
					Value: []byte("Test Location"),
				},
			},
			expectedResult: true,
			expectedDevice: &DiscoveredDevice{
				SysDescr:    "Test System Description",
				SysObjectID: ".1.3.6.1.4.1.9.1.1",
				Uptime:      12345,
				SysContact:  "admin@example.com",
				Hostname:    "test-device",
				SysLocation: "Test Location",
				Metadata:    map[string]string{},
			},
		},
		{
			name: "no valid variables",
			variables: []gosnmp.SnmpPDU{
				{
					Name: oidSysDescr,
					Type: gosnmp.NoSuchObject,
				},
				{
					Name: oidSysObjectID,
					Type: gosnmp.NoSuchInstance,
				},
			},
			expectedResult: false,
			expectedDevice: &DiscoveredDevice{
				Metadata: map[string]string{},
			},
		},
		{
			name:           "empty variables",
			variables:      []gosnmp.SnmpPDU{},
			expectedResult: false,
			expectedDevice: &DiscoveredDevice{
				Metadata: map[string]string{},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}
			device := &DiscoveredDevice{
				Metadata: map[string]string{},
			}

			result := engine.processSNMPVariables(device, tt.variables)

			assert.Equal(t, tt.expectedResult, result)
			assert.Equal(t, tt.expectedDevice.SysDescr, device.SysDescr)
			assert.Equal(t, tt.expectedDevice.SysObjectID, device.SysObjectID)
			assert.Equal(t, tt.expectedDevice.Uptime, device.Uptime)
			assert.Equal(t, tt.expectedDevice.SysContact, device.SysContact)
			assert.Equal(t, tt.expectedDevice.Hostname, device.Hostname)
			assert.Equal(t, tt.expectedDevice.SysLocation, device.SysLocation)
		})
	}
}

func TestSetStringValue(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected string
	}{
		{
			name: "valid octet string",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte("test string"),
			},
			expected: "test string",
		},
		{
			name: "empty octet string",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte(""),
			},
			expected: "",
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			expected: "original", // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			var target string

			if tt.name == "wrong type" {
				target = "original"
			}

			engine.setStringValue(&target, tt.pdu)
			assert.Equal(t, tt.expected, target)
		})
	}
}

func TestSetObjectIDValue(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected string
	}{
		{
			name: "valid object identifier",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.ObjectIdentifier,
				Value: ".1.3.6.1.4.1.9.1.1",
			},
			expected: ".1.3.6.1.4.1.9.1.1",
		},
		{
			name: "empty object identifier",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.ObjectIdentifier,
				Value: "",
			},
			expected: "",
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			expected: "original", // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			var target string

			if tt.name == "wrong type" {
				target = "original"
			}

			engine.setObjectIDValue(&target, tt.pdu)
			assert.Equal(t, tt.expected, target)
		})
	}
}

func TestSetUptimeValue(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected int64
	}{
		{
			name: "valid timeticks",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.TimeTicks,
				Value: uint32(12345),
			},
			expected: 12345,
		},
		{
			name: "zero timeticks",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.TimeTicks,
				Value: uint32(0),
			},
			expected: 0,
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			expected: 9999, // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			var target int64

			if tt.name == "wrong type" {
				target = 9999
			}

			engine.setUptimeValue(&target, tt.pdu)
			assert.Equal(t, tt.expected, target)
		})
	}
}

func TestUpdateIfPhysAddress(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected string
	}{
		{
			name: "valid MAC address",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
			},
			expected: "00:11:22:33:44:55",
		},
		{
			name: "empty MAC address",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte{},
			},
			expected: "",
		},
		{
			name: "invalid MAC address length",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte{0x00, 0x11, 0x22, 0x33, 0x44}, // Only 5 bytes
			},
			expected: "",
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 42,
			},
			expected: "original", // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{}
			if tt.name == "wrong type" {
				iface.IfPhysAddress = "original"
			}

			updateIfPhysAddress(iface, tt.pdu)
			assert.Equal(t, tt.expected, iface.IfPhysAddress)
		})
	}
}

// testStatusHelper is a helper for status update tests
func testStatusHelper(t *testing.T, statusType string, updateFunc func(*DiscoveryEngine, *DiscoveredInterface, gosnmp.SnmpPDU), getStatus func(*DiscoveredInterface) int32) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected int32
	}{
		{
			name: statusType + " up",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 1, // up
			},
			expected: 1,
		},
		{
			name: statusType + " down",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 2, // down
			},
			expected: 2,
		},
		{
			name: statusType + " testing",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 3, // testing
			},
			expected: 3,
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte("not an integer"),
			},
			expected: 0, // Should not change from default
		},
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{}

			updateFunc(engine, iface, tt.pdu)
			assert.Equal(t, tt.expected, getStatus(iface))
		})
	}
}

func TestUpdateIfAdminStatus(t *testing.T) {
	testStatusHelper(t, "admin status",
		(*DiscoveryEngine).updateIfAdminStatus,
		func(iface *DiscoveredInterface) int32 { return iface.IfAdminStatus })
}

func TestUpdateIfOperStatus(t *testing.T) {
	testStatusHelper(t, "oper status",
		(*DiscoveryEngine).updateIfOperStatus,
		func(iface *DiscoveredInterface) int32 { return iface.IfOperStatus })
}

func TestUpdateInterfaceHighSpeed(t *testing.T) {
	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected uint64
	}{
		{
			name: "valid high speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 1000, // 1 Gbps
			},
			expected: 1000000000, // 1 Gbps in bps
		},
		{
			name: "zero high speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 0,
			},
			expected: 0,
		},
		{
			name: "wrong type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte("not an integer"),
			},
			expected: 100000000, // Should not change from initial value
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{
				IfSpeed: 100000000, // Initial value
			}

			updateInterfaceHighSpeed(iface, tt.pdu)
			assert.Equal(t, tt.expected, iface.IfSpeed)
		})
	}
}

func TestUpdateIfSpeed(t *testing.T) {
	// Define the maxUint32Value constant if it's not accessible from the test
	const maxUint32Value = 4294967295

	tests := []struct {
		name     string
		pdu      gosnmp.SnmpPDU
		expected uint64
	}{
		{
			name: "gauge32 normal speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Gauge32,
				Value: uint32(100000000), // 100 Mbps
			},
			expected: 100000000,
		},
		{
			name: "gauge32 max value",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Gauge32,
				Value: uint32(maxUint32Value),
			},
			expected: 0, // Should be 0 as it indicates we need to check ifHighSpeed
		},
		{
			name: "counter32 speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Counter32,
				Value: uint32(100000000), // 100 Mbps
			},
			expected: 100000000,
		},
		{
			name: "counter64 speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Counter64,
				Value: uint64(10000000000), // 10 Gbps
			},
			expected: 10000000000,
		},
		{
			name: "integer speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Integer,
				Value: 100000000, // 100 Mbps
			},
			expected: 100000000,
		},
		{
			name: "uinteger32 speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.Uinteger32,
				Value: uint32(100000000), // 100 Mbps
			},
			expected: 100000000,
		},
		{
			name: "octet string speed",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.OctetString,
				Value: []byte{0x05, 0xF5, 0xE1, 0x00}, // 100000000 in big-endian
			},
			expected: 100000000,
		},
		{
			name: "unsupported type",
			pdu: gosnmp.SnmpPDU{
				Type:  gosnmp.IPAddress,
				Value: "192.168.1.1",
			},
			expected: 0, // Should not change from default
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			iface := &DiscoveredInterface{}
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			engine.updateIfSpeed(iface, tt.pdu)
			assert.Equal(t, tt.expected, iface.IfSpeed)
		})
	}
}

func TestUpdateInterfaceFromOID(t *testing.T) {
	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name      string
		iface     *DiscoveredInterface
		oidPrefix string
		pdu       gosnmp.SnmpPDU
		expected  *DiscoveredInterface
	}{
		{
			name:      "ifDescr update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfDescr,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfDescr + ".1",
				Type:  gosnmp.OctetString,
				Value: []byte("GigabitEthernet0/1"),
			},
			expected: &DiscoveredInterface{
				IfDescr: "GigabitEthernet0/1",
			},
		},
		{
			name:      "ifType update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfType,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfType + ".1",
				Type:  gosnmp.Integer,
				Value: 6, // ethernetCsmacd
			},
			expected: &DiscoveredInterface{
				IfType: 6,
			},
		},
		{
			name:      "ifSpeed update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfSpeed,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfSpeed + ".1",
				Type:  gosnmp.Gauge32,
				Value: uint32(100000000), // 100 Mbps
			},
			expected: &DiscoveredInterface{
				IfSpeed: 100000000,
			},
		},
		{
			name:      "ifPhysAddress update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfPhysAddress,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfPhysAddress + ".1",
				Type:  gosnmp.OctetString,
				Value: []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
			},
			expected: &DiscoveredInterface{
				IfPhysAddress: "00:11:22:33:44:55",
			},
		},
		{
			name:      "ifAdminStatus update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfAdminStatus,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfAdminStatus + ".1",
				Type:  gosnmp.Integer,
				Value: 1, // up
			},
			expected: &DiscoveredInterface{
				IfAdminStatus: 1,
			},
		},
		{
			name:      "ifOperStatus update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfOperStatus,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfOperStatus + ".1",
				Type:  gosnmp.Integer,
				Value: 1, // up
			},
			expected: &DiscoveredInterface{
				IfOperStatus: 1,
			},
		},
		{
			name:      "ifName update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfName,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfName + ".1",
				Type:  gosnmp.OctetString,
				Value: []byte("Gi0/1"),
			},
			expected: &DiscoveredInterface{
				IfName: "Gi0/1",
			},
		},
		{
			name:      "ifAlias update",
			iface:     &DiscoveredInterface{},
			oidPrefix: oidIfAlias,
			pdu: gosnmp.SnmpPDU{
				Name:  oidIfAlias + ".1",
				Type:  gosnmp.OctetString,
				Value: []byte("Uplink to Router"),
			},
			expected: &DiscoveredInterface{
				IfAlias: "Uplink to Router",
			},
		},
		{
			name: "unknown OID",
			iface: &DiscoveredInterface{
				IfName: "Original",
			},
			oidPrefix: ".1.3.6.1.2.1.99.999", // Unknown OID
			pdu: gosnmp.SnmpPDU{
				Name:  ".1.3.6.1.2.1.99.999.1",
				Type:  gosnmp.OctetString,
				Value: []byte("Should not update"),
			},
			expected: &DiscoveredInterface{
				IfName: "Original", // Should not change
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine.updateInterfaceFromOID(tt.iface, tt.oidPrefix, tt.pdu)

			// Check specific field that should have been updated
			switch tt.oidPrefix {
			case oidIfDescr:
				assert.Equal(t, tt.expected.IfDescr, tt.iface.IfDescr)
			case oidIfType:
				assert.Equal(t, tt.expected.IfType, tt.iface.IfType)
			case oidIfSpeed:
				assert.Equal(t, tt.expected.IfSpeed, tt.iface.IfSpeed)
			case oidIfPhysAddress:
				assert.Equal(t, tt.expected.IfPhysAddress, tt.iface.IfPhysAddress)
			case oidIfAdminStatus:
				assert.Equal(t, tt.expected.IfAdminStatus, tt.iface.IfAdminStatus)
			case oidIfOperStatus:
				assert.Equal(t, tt.expected.IfOperStatus, tt.iface.IfOperStatus)
			case oidIfName:
				assert.Equal(t, tt.expected.IfName, tt.iface.IfName)
			case oidIfAlias:
				assert.Equal(t, tt.expected.IfAlias, tt.iface.IfAlias)
			default:
				// For unknown OID, verify nothing changed
				assert.Equal(t, tt.expected.IfName, tt.iface.IfName)
			}
		})
	}
}

func TestHandleIPAdEntIfIndex(t *testing.T) {
	tests := []struct {
		name        string
		pdu         gosnmp.SnmpPDU
		ipToIfIndex map[string]int
		expected    map[string]int
	}{
		{
			name: "valid IP and ifIndex",
			pdu: gosnmp.SnmpPDU{
				Name:  oidIPAdEntIfIndex + ".192.168.1.1",
				Type:  gosnmp.Integer,
				Value: 1,
			},
			ipToIfIndex: make(map[string]int),
			expected: map[string]int{
				"192.168.1.1": 1,
			},
		},
		{
			name: "invalid OID format",
			pdu: gosnmp.SnmpPDU{
				Name:  oidIPAdEntIfIndex + ".invalid",
				Type:  gosnmp.Integer,
				Value: 1,
			},
			ipToIfIndex: make(map[string]int),
			expected:    map[string]int{}, // Should not change
		},
		{
			name: "wrong PDU type",
			pdu: gosnmp.SnmpPDU{
				Name:  oidIPAdEntIfIndex + ".192.168.1.1",
				Type:  gosnmp.OctetString,
				Value: []byte("not an integer"),
			},
			ipToIfIndex: make(map[string]int),
			expected:    map[string]int{}, // Should not change
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handleIPAdEntIfIndex(tt.pdu, tt.ipToIfIndex)
			assert.Equal(t, tt.expected, tt.ipToIfIndex)
		})
	}
}
