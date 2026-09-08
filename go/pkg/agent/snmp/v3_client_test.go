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
