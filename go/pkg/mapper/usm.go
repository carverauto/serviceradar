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
	"fmt"
	"strings"

	"github.com/gosnmp/gosnmp"
)

func applySNMPv3(client *gosnmp.GoSNMP, credentials *SNMPCredentials) error {
	if credentials == nil {
		return fmt.Errorf("%w: missing credentials", ErrInvalidSNMPv3Config)
	}

	if strings.TrimSpace(credentials.Username) == "" {
		return fmt.Errorf("%w: username is required", ErrInvalidSNMPv3Config)
	}

	flags, err := snmpv3MsgFlags(credentials.SecurityLevel, credentials)
	if err != nil {
		return err
	}

	usm := &gosnmp.UsmSecurityParameters{
		UserName: credentials.Username,
	}

	if flags == gosnmp.AuthNoPriv || flags == gosnmp.AuthPriv {
		authProto, err := normalizeSNMPAuthProtocol(credentials.AuthProtocol)
		if err != nil {
			return err
		}

		if strings.TrimSpace(credentials.AuthPassword) == "" {
			return fmt.Errorf("%w: auth password is required", ErrInvalidSNMPv3Config)
		}

		usm.AuthenticationProtocol = authProto
		usm.AuthenticationPassphrase = credentials.AuthPassword
	}

	if flags == gosnmp.AuthPriv {
		privProto, err := normalizeSNMPPrivProtocol(credentials.PrivacyProtocol)
		if err != nil {
			return err
		}

		if strings.TrimSpace(credentials.PrivacyPassword) == "" {
			return fmt.Errorf("%w: privacy password is required", ErrInvalidSNMPv3Config)
		}

		usm.PrivacyProtocol = privProto
		usm.PrivacyPassphrase = credentials.PrivacyPassword
	}

	client.Version = gosnmp.Version3
	client.SecurityModel = gosnmp.UserSecurityModel
	client.MsgFlags = flags
	client.SecurityParameters = usm

	return nil
}

func snmpv3MsgFlags(level string, credentials *SNMPCredentials) (gosnmp.SnmpV3MsgFlags, error) {
	normalized := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(level), "_", ""))
	normalized = strings.ReplaceAll(normalized, "-", "")

	switch normalized {
	case "":
		if credentials != nil && strings.TrimSpace(credentials.PrivacyPassword) != "" {
			return gosnmp.AuthPriv, nil
		}

		if credentials != nil && strings.TrimSpace(credentials.AuthPassword) != "" {
			return gosnmp.AuthNoPriv, nil
		}

		return gosnmp.NoAuthNoPriv, nil
	case "noauthnopriv":
		return gosnmp.NoAuthNoPriv, nil
	case "authnopriv":
		return gosnmp.AuthNoPriv, nil
	case "authpriv":
		return gosnmp.AuthPriv, nil
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPSecurityLevel, level)
	}
}

func normalizeSNMPAuthProtocol(value string) (gosnmp.SnmpV3AuthProtocol, error) {
	switch compactSNMPProtocol(value) {
	case "md5":
		return gosnmp.MD5, nil
	case "sha", "sha1":
		return gosnmp.SHA, nil
	case "sha224":
		return gosnmp.SHA224, nil
	case "sha256":
		return gosnmp.SHA256, nil
	case "sha384":
		return gosnmp.SHA384, nil
	case "sha512":
		return gosnmp.SHA512, nil
	case "":
		return 0, fmt.Errorf("%w: auth protocol is required", ErrUnknownSNMPAuthProtocol)
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPAuthProtocol, value)
	}
}

func normalizeSNMPPrivProtocol(value string) (gosnmp.SnmpV3PrivProtocol, error) {
	switch compactSNMPProtocol(value) {
	case "des":
		return gosnmp.DES, nil
	case "aes", "aes128":
		return gosnmp.AES, nil
	case "aes192":
		return gosnmp.AES192, nil
	case "aes256":
		return gosnmp.AES256, nil
	case "aes192c":
		return gosnmp.AES192C, nil
	case "aes256c":
		return gosnmp.AES256C, nil
	case "":
		return 0, fmt.Errorf("%w: privacy protocol is required", ErrUnknownSNMPPrivProtocol)
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPPrivProtocol, value)
	}
}

func compactSNMPProtocol(value string) string {
	trimmed := strings.ToLower(strings.TrimSpace(value))
	trimmed = strings.ReplaceAll(trimmed, "-", "")
	trimmed = strings.ReplaceAll(trimmed, "_", "")

	return trimmed
}
