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
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewSNMPClientAuthPrivHyphenatedProtocols(t *testing.T) {
	client, err := newSNMPClient(&Target{
		Host:    "127.0.0.1",
		Port:    161,
		Version: Version3,
		Timeout: Duration(time.Second),
		Retries: 0,
		V3Auth: &V3Auth{
			Username:      "serviceradar",
			SecurityLevel: SecurityLevelAuthPriv,
			AuthProtocol:  "SHA-256",
			AuthPassword:  "auth-secret",
			PrivProtocol:  "AES-256",
			PrivPassword:  "priv-secret",
		},
	})
	require.NoError(t, err)

	impl, ok := client.(*SNMPClientImpl)
	require.True(t, ok)
	assert.Equal(t, gosnmp.Version3, impl.client.Version)
	assert.Equal(t, gosnmp.UserSecurityModel, impl.client.SecurityModel)
	assert.Equal(t, gosnmp.AuthPriv, impl.client.MsgFlags)

	usm := impl.client.SecurityParameters.(*gosnmp.UsmSecurityParameters)
	assert.Equal(t, gosnmp.SHA256, usm.AuthenticationProtocol)
	assert.Equal(t, gosnmp.AES256, usm.PrivacyProtocol)
}

func TestNewSNMPClientRejectsUnknownAuthProtocol(t *testing.T) {
	_, err := newSNMPClient(&Target{
		Host:    "127.0.0.1",
		Port:    161,
		Version: Version3,
		V3Auth: &V3Auth{
			Username:      "serviceradar",
			SecurityLevel: SecurityLevelAuthPriv,
			AuthProtocol:  "SHA3",
			AuthPassword:  "auth-secret",
			PrivProtocol:  "AES",
			PrivPassword:  "priv-secret",
		},
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrUnknownSNMPAuthProtocol)
}

func TestNewSNMPClientRejectsMissingV3Auth(t *testing.T) {
	_, err := newSNMPClient(&Target{
		Host:    "127.0.0.1",
		Port:    161,
		Version: Version3,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrInvalidTargetConfig)
}

// snmpv3ProtocolContract is testdata/snmpv3_protocol_contract.json: the names
// core's forms offer and the spelling core sends for each. Core's
// ProtocolFormatter tests read the same file.
type snmpv3ProtocolContract struct {
	SecurityLevels []snmpv3ContractName `json:"security_levels"`
	AuthProtocols  []snmpv3ContractName `json:"auth_protocols"`
	PrivProtocols  []snmpv3ContractName `json:"priv_protocols"`
}

type snmpv3ContractName struct {
	Value string `json:"value"`
	Wire  string `json:"wire"`
}

func loadSNMPv3ProtocolContract(t *testing.T) snmpv3ProtocolContract {
	t.Helper()

	data, err := os.ReadFile(filepath.Join("testdata", "snmpv3_protocol_contract.json"))
	require.NoError(t, err)

	var contract snmpv3ProtocolContract
	require.NoError(t, json.Unmarshal(data, &contract))
	require.NotEmpty(t, contract.SecurityLevels)
	require.NotEmpty(t, contract.AuthProtocols)
	require.NotEmpty(t, contract.PrivProtocols)

	return contract
}

// offeredSet resolves every name core offers, in both spellings, and returns
// what they resolved to. Two offered names that resolve to the same thing are a
// failure: core would be presenting one protocol as two choices.
func offeredSet[T comparable](
	t *testing.T, names []snmpv3ContractName, resolve func(string) (T, error),
) map[T]struct{} {
	t.Helper()

	offered := make(map[T]struct{}, len(names))

	for _, name := range names {
		resolved, err := resolve(name.Value)
		require.NoErrorf(t, err, "core offers %q, which the agent rejects", name.Value)

		onWire, err := resolve(name.Wire)
		require.NoErrorf(t, err, "core sends %q, which the agent rejects", name.Wire)
		require.Equalf(t, resolved, onWire, "%q and its wire spelling %q differ", name.Value, name.Wire)

		_, duplicate := offered[resolved]
		require.Falsef(t, duplicate, "%q resolves to a protocol another offered name already has", name.Value)

		offered[resolved] = struct{}{}
	}

	return offered
}

func acceptedSet[T comparable](table map[string]T) map[T]struct{} {
	accepted := make(map[T]struct{}, len(table))
	for _, value := range table {
		accepted[value] = struct{}{}
	}

	return accepted
}

// Both directions: every name core offers is accepted here, and every level
// and protocol this agent accepts is one core offers.
func TestSNMPv3ProtocolContract(t *testing.T) {
	contract := loadSNMPv3ProtocolContract(t)

	assert.Equal(t,
		acceptedSet(securityLevelsByName()),
		offeredSet(t, contract.SecurityLevels, func(name string) (gosnmp.SnmpV3MsgFlags, error) {
			return securityLevelToMsgFlags(SecurityLevel(name))
		}),
		"security levels the agent accepts and core offers differ")

	assert.Equal(t,
		acceptedSet(authProtocolsByName()),
		offeredSet(t, contract.AuthProtocols, func(name string) (gosnmp.SnmpV3AuthProtocol, error) {
			return authProtocolToGoSNMP(AuthProtocol(name))
		}),
		"authentication protocols the agent accepts and core offers differ")

	assert.Equal(t,
		acceptedSet(privProtocolsByName()),
		offeredSet(t, contract.PrivProtocols, func(name string) (gosnmp.SnmpV3PrivProtocol, error) {
			return privProtocolToGoSNMP(PrivProtocol(name))
		}),
		"privacy protocols the agent accepts and core offers differ")
}
