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

package snmp

import (
	"testing"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/require"
)

func TestConvertVariable_OctetStringBytes(t *testing.T) {
	client := &SNMPClientImpl{}

	variable := gosnmp.SnmpPDU{
		Name:  ".1.3.6.1.2.1.1.1.0",
		Type:  gosnmp.OctetString,
		Value: []byte("Test SNMP String"),
	}

	value, err := client.convertVariable(variable)
	require.NoError(t, err)
	require.Equal(t, "Test SNMP String", value)
}

func TestConvertVariable_ObjectDescriptionBytes(t *testing.T) {
	client := &SNMPClientImpl{}

	variable := gosnmp.SnmpPDU{
		Name:  ".1.3.6.1.2.1.1.1.0",
		Type:  gosnmp.ObjectDescription,
		Value: []byte("Device OS v1.2.3"),
	}

	value, err := client.convertVariable(variable)
	require.NoError(t, err)
	require.Equal(t, "Device OS v1.2.3", value)
}

func TestConvertVariable_StringTypesUnexpectedValueDoNotPanic(t *testing.T) {
	client := &SNMPClientImpl{}

	testCases := []struct {
		name     string
		variable gosnmp.SnmpPDU
	}{
		{
			name: "OctetString byte",
			variable: gosnmp.SnmpPDU{
				Name:  ".1.3.6.1.2.1.1.1.0",
				Type:  gosnmp.OctetString,
				Value: byte('x'),
			},
		},
		{
			name: "ObjectDescription string",
			variable: gosnmp.SnmpPDU{
				Name:  ".1.3.6.1.2.1.1.1.0",
				Type:  gosnmp.ObjectDescription,
				Value: "not-bytes",
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var (
				value interface{}
				err   error
			)

			require.NotPanics(t, func() {
				value, err = client.convertVariable(tc.variable)
			})

			require.Nil(t, value)
			require.Error(t, err)
			require.ErrorIs(t, err, ErrSNMPConvert)
		})
	}
}
