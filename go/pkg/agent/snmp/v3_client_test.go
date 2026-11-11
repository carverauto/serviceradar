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

// A name the agent does not know, or none at all, must fail the target. It
// must never be polled with some other protocol in its place.
func TestNewSNMPClientRejectsUnknownOrMissingProtocols(t *testing.T) {
	tests := []struct {
		name         string
		authProtocol AuthProtocol
		privProtocol PrivProtocol
		want         error
	}{
		{"unknown auth protocol", "SHA3", "AES", ErrUnknownSNMPAuthProtocol},
		{"missing auth protocol", "", "AES", ErrUnknownSNMPAuthProtocol},
		{"unknown privacy protocol", "SHA", "AES512", ErrUnknownSNMPPrivProtocol},
		{"Cisco suffix on a protocol that has no such variant", "SHA", "AES-128-C", ErrUnknownSNMPPrivProtocol},
		{"missing privacy protocol", "SHA", "", ErrUnknownSNMPPrivProtocol},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := newSNMPClient(&Target{
				Host:    "127.0.0.1",
				Port:    161,
				Version: Version3,
				V3Auth: &V3Auth{
					Username:      "serviceradar",
					SecurityLevel: SecurityLevelAuthPriv,
					AuthProtocol:  tt.authProtocol,
					AuthPassword:  "auth-secret",
					PrivProtocol:  tt.privProtocol,
					PrivPassword:  "priv-secret",
				},
			})
			require.ErrorIs(t, err, tt.want)
			require.ErrorIs(t, err, ErrInvalidTargetConfig)
		})
	}
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

// usmFor builds the client a poller target with these protocols gets and
// returns the USM parameters gosnmp will use for it.
func usmFor(t *testing.T, authProtocol AuthProtocol, privProtocol PrivProtocol) *gosnmp.UsmSecurityParameters {
	t.Helper()

	client, err := newSNMPClient(&Target{
		Host:    "192.0.2.10",
		Port:    161,
		Version: Version3,
		V3Auth: &V3Auth{
			Username:      "serviceradar",
			SecurityLevel: SecurityLevelAuthPriv,
			AuthProtocol:  authProtocol,
			AuthPassword:  "auth-secret",
			PrivProtocol:  privProtocol,
			PrivPassword:  "priv-secret",
		},
	})
	require.NoErrorf(t, err, "auth %q, privacy %q", authProtocol, privProtocol)

	impl, ok := client.(*SNMPClientImpl)
	require.True(t, ok)

	usm, ok := impl.client.SecurityParameters.(*gosnmp.UsmSecurityParameters)
	require.True(t, ok)

	return usm
}

// Each name core offers must select its own gosnmp protocol, in the spelling a
// credential stores (which is also what a proto-delivered target carries) and
// in the spelling of compiled agent config. Accepting the name is not enough:
// AES-192-C polled as AES-192 is accepted and then cannot decrypt, because the
// Cisco variants extend the privacy key differently.
func TestSNMPv3OfferedNamesSelectTheirOwnProtocol(t *testing.T) {
	contract := loadSNMPv3ProtocolContract(t)

	wantAuth := map[string]gosnmp.SnmpV3AuthProtocol{
		"MD5":    gosnmp.MD5,
		"SHA":    gosnmp.SHA,
		"SHA224": gosnmp.SHA224,
		"SHA256": gosnmp.SHA256,
		"SHA384": gosnmp.SHA384,
		"SHA512": gosnmp.SHA512,
	}

	wantPriv := map[string]gosnmp.SnmpV3PrivProtocol{
		"DES":       gosnmp.DES,
		"AES":       gosnmp.AES,
		"AES192":    gosnmp.AES192,
		"AES256":    gosnmp.AES256,
		"AES-192-C": gosnmp.AES192C,
		"AES-256-C": gosnmp.AES256C,
	}

	for _, name := range contract.AuthProtocols {
		want, ok := wantAuth[name.Value]
		require.Truef(t, ok, "core offers auth protocol %q; say here which gosnmp protocol it is", name.Value)

		for _, spelling := range []string{name.Value, name.Wire} {
			assert.Equalf(t, want, usmFor(t, AuthProtocol(spelling), PrivProtocolAES).AuthenticationProtocol,
				"auth protocol %q", spelling)
		}
	}

	for _, name := range contract.PrivProtocols {
		want, ok := wantPriv[name.Value]
		require.Truef(t, ok, "core offers privacy protocol %q; say here which gosnmp protocol it is", name.Value)

		for _, spelling := range []string{name.Value, name.Wire} {
			assert.Equalf(t, want, usmFor(t, AuthProtocolSHA, PrivProtocol(spelling)).PrivacyProtocol,
				"privacy protocol %q", spelling)
		}
	}
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
