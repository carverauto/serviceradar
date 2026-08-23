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

	"time"
)

// safeInt32 safely converts an int to int32, preventing overflow
func safeInt32(val int) int32 {
	if val > math.MaxInt32 {
		return math.MaxInt32
	} else if val < math.MinInt32 {
		return math.MinInt32
	}

	return int32(val)
}

// Common SNMP OIDs - defined as constants for clarity and maintainability
const (
	// System OIDs
	oidSysDescr                = ".1.3.6.1.2.1.1.1.0"
	oidSysObjectID             = ".1.3.6.1.2.1.1.2.0"
	oidSysUptime               = ".1.3.6.1.2.1.1.3.0"
	oidSysContact              = ".1.3.6.1.2.1.1.4.0"
	oidSysName                 = ".1.3.6.1.2.1.1.5.0"
	oidSysLocation             = ".1.3.6.1.2.1.1.6.0"
	oidIPForwarding            = ".1.3.6.1.2.1.4.1.0"
	oidDot1dBaseBridgeAddress  = ".1.3.6.1.2.1.17.1.1.0"
	oidDot1dBaseNumPorts       = ".1.3.6.1.2.1.17.1.2.0"
	oidDot1dStpPortState       = ".1.3.6.1.2.1.17.2.15.1.3"
	oidDot1dBasePortIfIndex    = ".1.3.6.1.2.1.17.1.4.1.2"
	oidDot1dTpFdbPort          = ".1.3.6.1.2.1.17.4.3.1.2"
	oidDot1qTpFdbPort          = ".1.3.6.1.2.1.17.7.2.2.1.2"
	oidDot1qVlanCurrentEgress  = ".1.3.6.1.2.1.17.7.1.4.2.1.4"
	oidDot1qVlanStaticEgress   = ".1.3.6.1.2.1.17.7.1.4.3.1.2"
	oidDot1qVlanStaticUntagged = ".1.3.6.1.2.1.17.7.1.4.3.1.4"
	oidDot1qPvid               = ".1.3.6.1.2.1.17.7.1.4.5.1.1"

	// Interface table OIDs
	oidIfTable = ".1.3.6.1.2.1.2.2.1"
	// oidIfIndex       = ".1.3.6.1.2.1.2.2.1.1"
	oidIfDescr = ".1.3.6.1.2.1.2.2.1.2"
	oidIfType  = ".1.3.6.1.2.1.2.2.1.3"
	// oidIfMtu         = ".1.3.6.1.2.1.2.2.1.4"
	oidIfSpeed       = ".1.3.6.1.2.1.2.2.1.5"
	oidIfPhysAddress = ".1.3.6.1.2.1.2.2.1.6"
	oidIfAdminStatus = ".1.3.6.1.2.1.2.2.1.7"
	oidIfOperStatus  = ".1.3.6.1.2.1.2.2.1.8"

	// IP address table OIDs
	oidIPAddrTable      = ".1.3.6.1.2.1.4.20.1"
	oidIPAdEntAddr      = ".1.3.6.1.2.1.4.20.1.1"
	oidIPAdEntIfIndex   = ".1.3.6.1.2.1.4.20.1.2"
	// ipAddressTable (IP-MIB, RFC 4293). Unlike the legacy ipAddrTable above,
	// which is structurally IPv4-only, this one is address-family aware: its
	// INDEX carries an InetAddressType, so it is the ONLY standard way to learn
	// a device's IPv6 addresses over SNMP.
	oidIPAddressTable   = ".1.3.6.1.2.1.4.34"
	oidIPAddressIfIndex = ".1.3.6.1.2.1.4.34.1.3"
	oidIPNetToMedia     = ".1.3.6.1.2.1.4.22.1"
	oidIPToMediaPhys    = ".1.3.6.1.2.1.4.22.1.2"
	oidIPToPhysicalPhys = ".1.3.6.1.2.1.4.35.1.4"

	// Extended interface table (ifXTable)
	oidIfXTable    = ".1.3.6.1.2.1.31.1.1.1"
	oidIfName      = ".1.3.6.1.2.1.31.1.1.1.1"
	oidIfAlias     = ".1.3.6.1.2.1.31.1.1.1.18"
	oidIfHighSpeed = ".1.3.6.1.2.1.31.1.1.1.15"

	// Interface metric probing is best-effort. Large switches can expose hundreds of
	// interfaces, and probing every interface inline can exceed the discovery timeout
	// before the discovered interfaces are ever published.
	interfaceMetricProbeBudget = 5 * time.Second
	interfaceMetricProbeMax    = 64

	// LLDP OIDs
	oidLLDPRemTable = ".1.0.8802.1.1.2.1.4.1.1"
	// oidLldpRemChassisId = ".1.0.8802.1.1.2.1.4.1.1.5"
	// oidLldpRemPortId    = ".1.0.8802.1.1.2.1.4.1.1.7"
	// oidLldpRemPortDesc  = ".1.0.8802.1.1.2.1.4.1.1.8"
	// oidLldpRemSysName   = ".1.0.8802.1.1.2.1.4.1.1.9"
	// oidLLDPRemManAddr = ".1.0.8802.1.1.2.1.4.2.1.3"
	oidLLDPRemManAddr = ".1.0.8802.1.1.2.1.4.2.1.3"

	// CDP OIDs (Cisco Discovery Protocol)
	// oidCDPCacheTable = ".1.3.6.1.4.1.9.9.23.1.2.1.1"
	oidCDPCacheTable = ".1.3.6.1.4.1.9.9.23.1.2.1.1"
	// oidCdpCacheDeviceId   = ".1.3.6.1.4.1.9.9.23.1.2.1.1.6"
	// oidCdpCacheDevicePort = ".1.3.6.1.4.1.9.9.23.1.2.1.1.7"
	// oidCdpCacheAddress    = ".1.3.6.1.4.1.9.9.23.1.2.1.1.4"

	// Interface metrics OIDs (32-bit counters from IF-MIB)
	oidIfInOctets     = ".1.3.6.1.2.1.2.2.1.10"
	oidIfOutOctets    = ".1.3.6.1.2.1.2.2.1.16"
	oidIfInErrors     = ".1.3.6.1.2.1.2.2.1.14"
	oidIfOutErrors    = ".1.3.6.1.2.1.2.2.1.20"
	oidIfInDiscards   = ".1.3.6.1.2.1.2.2.1.13"
	oidIfOutDiscards  = ".1.3.6.1.2.1.2.2.1.19"
	oidIfInUcastPkts  = ".1.3.6.1.2.1.2.2.1.11"
	oidIfOutUcastPkts = ".1.3.6.1.2.1.2.2.1.17"

	// Interface metrics OIDs (64-bit counters from IF-MIB extensions)
	oidIfHCInOctets     = ".1.3.6.1.2.1.31.1.1.1.6"
	oidIfHCOutOctets    = ".1.3.6.1.2.1.31.1.1.1.10"
	oidIfHCInUcastPkts  = ".1.3.6.1.2.1.31.1.1.1.7"
	oidIfHCOutUcastPkts = ".1.3.6.1.2.1.31.1.1.1.11"

	defaultMaxIPRange = 256 // Maximum IPs to process from a CIDR range
)

// interfaceMetricDef defines an interface metric to probe
type interfaceMetricDef struct {
	Name     string
	OID32    string
	OID64    string // Empty if no 64-bit variant exists
	DataType string // "counter" or "gauge"
	Category string // "traffic", "errors", "packets", "environmental", "status"
	Unit     string // "bytes", "packets", "errors", "celsius", "rpm", "percent", "watts"
}

// getStandardInterfaceMetrics returns the standard IF-MIB metrics to probe
func getStandardInterfaceMetrics() []interfaceMetricDef {
	return []interfaceMetricDef{
		// Traffic metrics (bytes)
		{Name: "ifInOctets", OID32: oidIfInOctets, OID64: oidIfHCInOctets, DataType: "counter", Category: "traffic", Unit: "bytes"},
		{Name: "ifOutOctets", OID32: oidIfOutOctets, OID64: oidIfHCOutOctets, DataType: "counter", Category: "traffic", Unit: "bytes"},
		// Error metrics
		{Name: "ifInErrors", OID32: oidIfInErrors, OID64: "", DataType: "counter", Category: "errors", Unit: "errors"},
		{Name: "ifOutErrors", OID32: oidIfOutErrors, OID64: "", DataType: "counter", Category: "errors", Unit: "errors"},
		{Name: "ifInDiscards", OID32: oidIfInDiscards, OID64: "", DataType: "counter", Category: "errors", Unit: "packets"},
		{Name: "ifOutDiscards", OID32: oidIfOutDiscards, OID64: "", DataType: "counter", Category: "errors", Unit: "packets"},
		// Packet metrics
		{Name: "ifInUcastPkts", OID32: oidIfInUcastPkts, OID64: oidIfHCInUcastPkts, DataType: "counter", Category: "packets", Unit: "packets"},
		{Name: "ifOutUcastPkts", OID32: oidIfOutUcastPkts, OID64: oidIfHCOutUcastPkts, DataType: "counter", Category: "packets", Unit: "packets"},
	}
}
