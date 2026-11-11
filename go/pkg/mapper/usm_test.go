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
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestApplySNMPv3SetsUserSecurityModelAndAuthPriv(t *testing.T) {
	client := &gosnmp.GoSNMP{Target: "127.0.0.1", Port: 161}
	err := applySNMPv3(client, &SNMPCredentials{
		Version:         SNMPVersion3,
		Username:        "serviceradar",
		SecurityLevel:   "authPriv",
		AuthProtocol:    "SHA",
		AuthPassword:    "auth-secret",
		PrivacyProtocol: "AES",
		PrivacyPassword: "auth-secret",
	})
	require.NoError(t, err)
	assert.Equal(t, gosnmp.Version3, client.Version)
	assert.Equal(t, gosnmp.UserSecurityModel, client.SecurityModel)
	assert.Equal(t, gosnmp.AuthPriv, client.MsgFlags)

	usm, ok := client.SecurityParameters.(*gosnmp.UsmSecurityParameters)
	require.True(t, ok)
	assert.Equal(t, "serviceradar", usm.UserName)
	assert.Equal(t, gosnmp.SHA, usm.AuthenticationProtocol)
	assert.Equal(t, gosnmp.AES, usm.PrivacyProtocol)
}

func TestApplySNMPv3AcceptsHyphenatedProtocols(t *testing.T) {
	client := &gosnmp.GoSNMP{Target: "127.0.0.1", Port: 161}
	err := applySNMPv3(client, &SNMPCredentials{
		Username:        "monitor",
		SecurityLevel:   "authPriv",
		AuthProtocol:    "SHA-256",
		AuthPassword:    "auth-secret",
		PrivacyProtocol: "AES-256",
		PrivacyPassword: "priv-secret",
	})
	require.NoError(t, err)
	usm := client.SecurityParameters.(*gosnmp.UsmSecurityParameters)
	assert.Equal(t, gosnmp.SHA256, usm.AuthenticationProtocol)
	assert.Equal(t, gosnmp.AES256, usm.PrivacyProtocol)
}

func TestApplySNMPv3AuthNoPrivAndNoAuthNoPriv(t *testing.T) {
	authNoPriv := &gosnmp.GoSNMP{}
	require.NoError(t, applySNMPv3(authNoPriv, &SNMPCredentials{
		Username:      "monitor",
		SecurityLevel: "authNoPriv",
		AuthProtocol:  "SHA",
		AuthPassword:  "auth-secret",
	}))
	assert.Equal(t, gosnmp.AuthNoPriv, authNoPriv.MsgFlags)
	assert.Equal(t, gosnmp.UserSecurityModel, authNoPriv.SecurityModel)

	noAuth := &gosnmp.GoSNMP{}
	require.NoError(t, applySNMPv3(noAuth, &SNMPCredentials{
		Username:      "monitor",
		SecurityLevel: "noAuthNoPriv",
	}))
	assert.Equal(t, gosnmp.NoAuthNoPriv, noAuth.MsgFlags)
}

// A name discovery does not know, or none at all, must fail the job. It must
// never be walked with some other protocol in its place.
func TestApplySNMPv3RejectsUnknownOrMissingProtocols(t *testing.T) {
	tests := []struct {
		name         string
		authProtocol string
		privProtocol string
		want         error
	}{
		{"unknown auth protocol", "SHA3", "AES", ErrUnknownSNMPAuthProtocol},
		{"missing auth protocol", "", "AES", ErrUnknownSNMPAuthProtocol},
		{"unknown privacy protocol", "SHA", "AES512", ErrUnknownSNMPPrivProtocol},
		{"Cisco suffix on a protocol that has no such variant", "SHA", "AES128C", ErrUnknownSNMPPrivProtocol},
		{"missing privacy protocol", "SHA", "", ErrUnknownSNMPPrivProtocol},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := applySNMPv3(&gosnmp.GoSNMP{}, &SNMPCredentials{
				Username:        "monitor",
				SecurityLevel:   "authPriv",
				AuthProtocol:    tt.authProtocol,
				AuthPassword:    "auth-secret",
				PrivacyProtocol: tt.privProtocol,
				PrivacyPassword: "priv-secret",
			})
			require.ErrorIs(t, err, tt.want)
		})
	}
}

func TestSNMPv3ConnectDoesNotRejectMissingSecurityModel(t *testing.T) {
	engine := &DiscoveryEngine{
		config: &Config{Timeout: 200 * time.Millisecond, Retries: 0},
		logger: logger.NewTestLogger(),
	}
	job := &DiscoveryJob{
		ID: "v3-usm",
		Params: &DiscoveryParams{
			Credentials: &SNMPCredentials{
				Version:         SNMPVersion3,
				Username:        "serviceradar",
				SecurityLevel:   "authPriv",
				AuthProtocol:    "SHA",
				AuthPassword:    "auth-secret",
				PrivacyProtocol: "AES",
				PrivacyPassword: "auth-secret",
			},
		},
	}

	client, err := engine.setupSNMPClient(job, "127.0.0.1")
	require.NoError(t, err)
	require.Equal(t, gosnmp.UserSecurityModel, client.SecurityModel)

	udp, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	require.NoError(t, err)
	t.Cleanup(func() { _ = udp.Close() })

	client.Target = "127.0.0.1"
	client.Port = uint16(udp.LocalAddr().(*net.UDPAddr).Port)
	client.Timeout = 50 * time.Millisecond
	client.Retries = 0

	err = client.Connect()
	require.NoError(t, err)
	require.NotNil(t, client.Conn)
	require.NoError(t, client.Conn.Close())
}

type offeredSNMPv3Name struct {
	Value  string `json:"value"`
	Wire   string `json:"wire"`
	Mapper string `json:"mapper"`
}

// requireOfferedProtocolsSelected resolves each offered protocol in every
// spelling core can deliver it in - most importantly the one core puts in
// discovery credentials - and requires the gosnmp protocol named for it in
// want. Accepting the name is not enough: AES-192-C resolved as AES-192 is
// accepted and then cannot decrypt.
func requireOfferedProtocolsSelected[T comparable](
	t *testing.T, names []offeredSNMPv3Name, want map[string]T, resolve func(string) (T, error),
) {
	t.Helper()

	for _, name := range names {
		expected, ok := want[name.Value]
		require.Truef(t, ok, "core offers %q; say here which gosnmp protocol it is", name.Value)
		require.NotEmptyf(t, name.Mapper, "%q has no discovery spelling in the contract", name.Value)

		for _, spelling := range []string{name.Mapper, name.Value, name.Wire} {
			resolved, err := resolve(spelling)
			require.NoErrorf(t, err, "discovery rejects %q", spelling)
			assert.Equalf(t, expected, resolved, "%q", spelling)
		}
	}
}

func TestSNMPv3OfferedProtocolsSelectTheirOwnProtocol(t *testing.T) {
	data, err := os.ReadFile(
		filepath.Join("..", "agent", "snmp", "testdata", "snmpv3_protocol_contract.json"))
	require.NoError(t, err)

	var contract struct {
		AuthProtocols []offeredSNMPv3Name `json:"auth_protocols"`
		PrivProtocols []offeredSNMPv3Name `json:"priv_protocols"`
	}

	require.NoError(t, json.Unmarshal(data, &contract))
	require.NotEmpty(t, contract.AuthProtocols)
	require.NotEmpty(t, contract.PrivProtocols)

	requireOfferedProtocolsSelected(t, contract.AuthProtocols,
		map[string]gosnmp.SnmpV3AuthProtocol{
			"MD5":    gosnmp.MD5,
			"SHA":    gosnmp.SHA,
			"SHA224": gosnmp.SHA224,
			"SHA256": gosnmp.SHA256,
			"SHA384": gosnmp.SHA384,
			"SHA512": gosnmp.SHA512,
		},
		func(name string) (gosnmp.SnmpV3AuthProtocol, error) {
			client := &gosnmp.GoSNMP{}
			err := applySNMPv3(client, &SNMPCredentials{
				Username:      "monitor",
				SecurityLevel: "authNoPriv",
				AuthProtocol:  name,
				AuthPassword:  "auth-secret",
			})
			if err != nil {
				return 0, err
			}

			return client.SecurityParameters.(*gosnmp.UsmSecurityParameters).AuthenticationProtocol, nil
		})

	requireOfferedProtocolsSelected(t, contract.PrivProtocols,
		map[string]gosnmp.SnmpV3PrivProtocol{
			"DES":       gosnmp.DES,
			"AES":       gosnmp.AES,
			"AES192":    gosnmp.AES192,
			"AES256":    gosnmp.AES256,
			"AES-192-C": gosnmp.AES192C,
			"AES-256-C": gosnmp.AES256C,
		},
		func(name string) (gosnmp.SnmpV3PrivProtocol, error) {
			client := &gosnmp.GoSNMP{}
			err := applySNMPv3(client, &SNMPCredentials{
				Username:        "monitor",
				SecurityLevel:   "authPriv",
				AuthProtocol:    "SHA",
				AuthPassword:    "auth-secret",
				PrivacyProtocol: name,
				PrivacyPassword: "priv-secret",
			})
			if err != nil {
				return 0, err
			}

			return client.SecurityParameters.(*gosnmp.UsmSecurityParameters).PrivacyProtocol, nil
		})
}

// requireOfferedNamesAccepted resolves each offered name in its stored and its
// wire spelling. Both must be accepted and agree, and no two offered names may
// resolve to the same thing.
func requireOfferedNamesAccepted[T comparable](
	t *testing.T, names []offeredSNMPv3Name, resolve func(string) (T, error),
) {
	t.Helper()
	require.NotEmpty(t, names)

	seen := make(map[T]string, len(names))

	for _, name := range names {
		resolved, err := resolve(name.Value)
		require.NoErrorf(t, err, "core offers %q, which discovery rejects", name.Value)

		onWire, err := resolve(name.Wire)
		require.NoErrorf(t, err, "core sends %q, which discovery rejects", name.Wire)
		require.Equalf(t, resolved, onWire, "%q and its wire spelling %q differ", name.Value, name.Wire)

		other, duplicate := seen[resolved]
		require.Falsef(t, duplicate, "%q and %q resolve to the same thing", name.Value, other)

		seen[resolved] = name.Value
	}
}

// Discovery resolves SNMPv3 names with its own switch statements, so it is held
// to the same list as the agent's poller: every security level and protocol
// core offers in its forms must be accepted here. The fixture is the one the
// agent's and core's tests read.
func TestSNMPv3NamesOfferedByCoreAreAccepted(t *testing.T) {
	data, err := os.ReadFile(
		filepath.Join("..", "agent", "snmp", "testdata", "snmpv3_protocol_contract.json"))
	require.NoError(t, err)

	var contract struct {
		SecurityLevels []offeredSNMPv3Name `json:"security_levels"`
		AuthProtocols  []offeredSNMPv3Name `json:"auth_protocols"`
		PrivProtocols  []offeredSNMPv3Name `json:"priv_protocols"`
	}

	require.NoError(t, json.Unmarshal(data, &contract))

	requireOfferedNamesAccepted(t, contract.SecurityLevels,
		func(name string) (gosnmp.SnmpV3MsgFlags, error) {
			return snmpv3MsgFlags(name, &SNMPCredentials{})
		})
	requireOfferedNamesAccepted(t, contract.AuthProtocols, normalizeSNMPAuthProtocol)
	requireOfferedNamesAccepted(t, contract.PrivProtocols, normalizeSNMPPrivProtocol)
}
