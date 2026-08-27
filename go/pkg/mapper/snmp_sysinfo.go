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

	"github.com/gosnmp/gosnmp"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func (e *DiscoveryEngine) generateDeviceID(job *DiscoveryJob, device *DiscoveredDevice, target string) {
	if existingID, existingMAC := e.resolveExistingDeviceIdentityByIP(job, target); existingID != "" &&
		!distinctHardwareMACs(device.MAC, existingMAC) {
		device.DeviceID = existingID
		if device.MAC == "" && existingMAC != "" {
			device.MAC = existingMAC
		}

		return
	}

	if device.DeviceID != "" {
		return
	}

	if id := GenerateDeviceID(device.MAC); id != "" {
		device.DeviceID = id
		return
	}

	device.DeviceID = GenerateDeviceIDFromIP(target)
}

// querySysInfo queries basic system information via SNMP
func (e *DiscoveryEngine) querySysInfo(
	client *gosnmp.GoSNMP, target string, job *DiscoveryJob) (*DiscoveredDevice, error) {
	// System OIDs to query
	oids := []string{
		oidSysDescr,
		oidSysObjectID,
		oidSysUptime,
		oidSysContact,
		oidSysName,
		oidSysLocation,
		oidIPForwarding,
		oidDot1dBaseBridgeAddress,
	}

	variables, err := fetchSystemVariables(client.Get, oids)
	if err != nil {
		return nil, err
	}

	// Create and initialize device
	device := e.initializeDevice(target)

	extractionErrors := make(map[string]string)

	// Process SNMP variables
	foundSomething := e.processSNMPVariablesWithErrors(device, variables, extractionErrors)
	if !foundSomething {
		return nil, ErrNoSNMPDataReturned
	}

	device.SNMPFingerprint = buildSNMPFingerprintFromDevice(device, extractionErrors)
	e.enrichSNMPBridgeFingerprint(client, device.SNMPFingerprint, extractionErrors)
	e.enrichSNMPVLANFingerprint(client, device.SNMPFingerprint, extractionErrors)

	// Finalize device setup
	e.finalizeDevice(job, device, target, job.ID, string(models.DiscoverySourceSNMP))

	// After getting basic info, try to get MAC if not already set
	if device.MAC == "" {
		device.MAC = e.getMACAddress(client, target, job.ID)
	}

	// Generate device ID
	e.generateDeviceID(job, device, target)

	return device, nil
}

func fetchSystemVariables(
	get func([]string) (*gosnmp.SnmpPacket, error),
	oids []string,
) ([]gosnmp.SnmpPDU, error) {
	result, err := get(oids)
	if err != nil {
		return nil, fmt.Errorf("%w %w", ErrSNMPGetFailed, err)
	}

	if result.Error == gosnmp.NoError {
		return result.Variables, nil
	}

	if isSNMPPacketNoDataError(result.Error) {
		return nil, fmt.Errorf("%w %s", ErrNoSNMPDataReturned, result.Error)
	}

	if !isSNMPPacketUnsupportedError(result.Error) {
		return nil, fmt.Errorf("%w %s", ErrSNMPError, result.Error)
	}

	variables := make([]gosnmp.SnmpPDU, 0, len(oids))

	for _, oid := range oids {
		single, singleErr := get([]string{oid})
		if singleErr != nil {
			if isSNMPOIDUnsupportedError(singleErr) {
				continue
			}

			return nil, fmt.Errorf("%w %w", ErrSNMPGetFailed, singleErr)
		}

		if single == nil {
			continue
		}

		if single.Error != gosnmp.NoError {
			if isSNMPPacketNoDataError(single.Error) {
				return nil, fmt.Errorf("%w %s", ErrNoSNMPDataReturned, single.Error)
			}

			if isSNMPPacketUnsupportedError(single.Error) {
				continue
			}

			return nil, fmt.Errorf("%w %s", ErrSNMPError, single.Error)
		}

		variables = append(variables, single.Variables...)
	}

	return variables, nil
}

func buildSNMPFingerprintFromDevice(device *DiscoveredDevice, extractionErrors map[string]string) *SNMPFingerprint {
	if device == nil {
		return nil
	}

	var copiedErrors map[string]string
	if len(extractionErrors) > 0 {
		copiedErrors = make(map[string]string, len(extractionErrors))
		for k, v := range extractionErrors {
			copiedErrors[k] = v
		}
	}

	return &SNMPFingerprint{
		System: &SNMPSystemFingerprint{
			SysName:      device.SysName,
			SysDescr:     device.SysDescr,
			SysObjectID:  device.SysObjectID,
			SysContact:   device.SysContact,
			SysLocation:  device.SysLocation,
			IPForwarding: device.IPForwarding,
		},
		Bridge: &SNMPBridgeFingerprint{
			BridgeBaseMAC: device.BridgeBaseMAC,
		},
		ExtractionErrors: copiedErrors,
	}
}
