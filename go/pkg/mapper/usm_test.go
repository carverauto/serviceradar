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
	"net"
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

func TestApplySNMPv3RejectsUnknownProtocol(t *testing.T) {
	err := applySNMPv3(&gosnmp.GoSNMP{}, &SNMPCredentials{
		Username:        "monitor",
		SecurityLevel:   "authPriv",
		AuthProtocol:    "SHA3",
		AuthPassword:    "auth-secret",
		PrivacyProtocol: "AES",
		PrivacyPassword: "priv-secret",
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrUnknownSNMPAuthProtocol)
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
