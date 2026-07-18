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
	"strings"
)

func (u *UniFiUplink) UnmarshalJSON(data []byte) error {
	type uplinkAlias UniFiUplink
	var raw struct {
		uplinkAlias
		LocalPortIdx      *int32 `json:"localPortIdx"`
		LocalPortIdxSnake *int32 `json:"local_port_idx"`
		PortIdx           *int32 `json:"portIdx"`
		PortIdxSnake      *int32 `json:"port_idx"`
		ParentPortIdx     *int32 `json:"parentPortIdx"`
		ParentPortSnake   *int32 `json:"parent_port_idx"`
	}

	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	*u = UniFiUplink(raw.uplinkAlias)
	if raw.LocalPortIdx != nil {
		u.LocalPortIdx = *raw.LocalPortIdx
		u.localPortIdxSet = true
	}
	if raw.LocalPortIdxSnake != nil {
		u.LocalPortIdxSnake = *raw.LocalPortIdxSnake
		u.localPortIdxSnakeSet = true
	}
	if raw.PortIdx != nil {
		u.PortIdx = *raw.PortIdx
		u.portIdxSet = true
	}
	if raw.PortIdxSnake != nil {
		u.PortIdxSnake = *raw.PortIdxSnake
		u.portIdxSnakeSet = true
	}
	if raw.ParentPortIdx != nil {
		u.ParentPortIdx = *raw.ParentPortIdx
		u.parentPortIdxSet = true
	}
	if raw.ParentPortSnake != nil {
		u.ParentPortSnake = *raw.ParentPortSnake
		u.parentPortSnakeSet = true
	}

	return nil
}

func (u UniFiUplink) upstreamDeviceID() string {
	if u.DeviceID != "" {
		return u.DeviceID
	}
	if u.DeviceIDSnake != "" {
		return u.DeviceIDSnake
	}
	if u.UpstreamID != "" {
		return u.UpstreamID
	}
	return u.UpstreamSnake
}

func (u UniFiUplink) parentPortIndex() int32 {
	switch {
	case (u.localPortIdxSet && u.LocalPortIdx >= 0) || u.LocalPortIdx > 0:
		return u.LocalPortIdx
	case (u.localPortIdxSnakeSet && u.LocalPortIdxSnake >= 0) || u.LocalPortIdxSnake > 0:
		return u.LocalPortIdxSnake
	case (u.portIdxSet && u.PortIdx >= 0) || u.PortIdx > 0:
		return u.PortIdx
	case (u.portIdxSnakeSet && u.PortIdxSnake >= 0) || u.PortIdxSnake > 0:
		return u.PortIdxSnake
	case (u.parentPortIdxSet && u.ParentPortIdx >= 0) || u.ParentPortIdx > 0:
		return u.ParentPortIdx
	case (u.parentPortSnakeSet && u.ParentPortSnake >= 0) || u.ParentPortSnake > 0:
		return u.ParentPortSnake
	default:
		return 0
	}
}

func (u UniFiUplink) parentPortIndexPresent() bool {
	return (u.localPortIdxSet && u.LocalPortIdx >= 0) ||
		(u.localPortIdxSnakeSet && u.LocalPortIdxSnake >= 0) ||
		(u.portIdxSet && u.PortIdx >= 0) ||
		(u.portIdxSnakeSet && u.PortIdxSnake >= 0) ||
		(u.parentPortIdxSet && u.ParentPortIdx >= 0) ||
		(u.parentPortSnakeSet && u.ParentPortSnake >= 0) ||
		u.LocalPortIdx > 0 ||
		u.LocalPortIdxSnake > 0 ||
		u.PortIdx > 0 ||
		u.PortIdxSnake > 0 ||
		u.ParentPortIdx > 0 ||
		u.ParentPortSnake > 0
}

func (u UniFiUplink) parentPortName() string {
	switch {
	case strings.TrimSpace(u.LocalPortName) != "":
		return strings.TrimSpace(u.LocalPortName)
	case strings.TrimSpace(u.LocalPortNameSnake) != "":
		return strings.TrimSpace(u.LocalPortNameSnake)
	case strings.TrimSpace(u.PortName) != "":
		return strings.TrimSpace(u.PortName)
	case strings.TrimSpace(u.PortNameSnake) != "":
		return strings.TrimSpace(u.PortNameSnake)
	case strings.TrimSpace(u.ParentPortName) != "":
		return strings.TrimSpace(u.ParentPortName)
	case strings.TrimSpace(u.ParentPortNameSnk) != "":
		return strings.TrimSpace(u.ParentPortNameSnk)
	default:
		return ""
	}
}

func (c UniFiClient) normalizedType() string {
	return strings.ToUpper(strings.TrimSpace(c.Type))
}

func (c UniFiClient) normalizedMAC() string {
	return strings.TrimSpace(c.MACAddress)
}

func (c UniFiClient) normalizedIP() string {
	return strings.TrimSpace(c.IPAddress)
}

func (c UniFiClient) normalizedName() string {
	return strings.TrimSpace(c.Name)
}

func (c UniFiClient) normalizedUplinkDeviceID() string {
	return strings.TrimSpace(c.UplinkDeviceID)
}

func (c UniFiClient) normalizedUplinkDeviceMAC() string {
	if strings.TrimSpace(c.UplinkDeviceMAC) != "" {
		return strings.TrimSpace(c.UplinkDeviceMAC)
	}

	return strings.TrimSpace(c.UplinkDeviceMACSnake)
}

func (c UniFiClient) uplinkPortIndex() int32 {
	switch {
	case c.UplinkPortIdx != nil:
		return *c.UplinkPortIdx
	case c.UplinkPortIdxSnake != nil:
		return *c.UplinkPortIdxSnake
	default:
		return 0
	}
}

// uplinkPortIndexPresent reports whether the payload carried a usable uplink
// port index. UniFi port indexes are 1-based; an explicit 0 is treated as
// unknown so the link degrades to switch-level attachment.
func (c UniFiClient) uplinkPortIndexPresent() bool {
	return c.uplinkPortIndex() > 0
}

func (a UniFiClientAccess) normalizedType() string {
	return strings.ToUpper(strings.TrimSpace(a.Type))
}

func (d *UniFiDeviceDetails) normalizedLLDPTable() []UniFiLLDPEntry {
	if len(d.LLDPTableCamel) > 0 {
		return d.LLDPTableCamel
	}

	return d.LLDPTable
}

func (d *UniFiDeviceDetails) normalizedPortTable() []UniFiPortEntry {
	if len(d.PortTableCamel) > 0 {
		return d.PortTableCamel
	}

	return d.PortTable
}

func (e UniFiLLDPEntry) ifIndex() int32 {
	if e.LocalPortIdxCamel > 0 {
		return e.LocalPortIdxCamel
	}

	return e.LocalPortIdx
}

func (e UniFiLLDPEntry) ifName() string {
	if strings.TrimSpace(e.LocalPortNameCamel) != "" {
		return strings.TrimSpace(e.LocalPortNameCamel)
	}

	return strings.TrimSpace(e.LocalPortName)
}

func (e UniFiLLDPEntry) chassisID() string {
	if strings.TrimSpace(e.ChassisIDCamel) != "" {
		return strings.TrimSpace(e.ChassisIDCamel)
	}

	return strings.TrimSpace(e.ChassisID)
}

func (e UniFiLLDPEntry) portID() string {
	if strings.TrimSpace(e.PortIDCamel) != "" {
		return strings.TrimSpace(e.PortIDCamel)
	}

	return strings.TrimSpace(e.PortID)
}

func (e UniFiLLDPEntry) portDescr() string {
	if strings.TrimSpace(e.PortDescrCamel) != "" {
		return strings.TrimSpace(e.PortDescrCamel)
	}

	return strings.TrimSpace(e.PortDescription)
}

func (e UniFiLLDPEntry) systemName() string {
	if strings.TrimSpace(e.SystemNameCamel) != "" {
		return strings.TrimSpace(e.SystemNameCamel)
	}

	return strings.TrimSpace(e.SystemName)
}

func (e UniFiLLDPEntry) mgmtAddr() string {
	if strings.TrimSpace(e.ManagementAddrCamel) != "" {
		return strings.TrimSpace(e.ManagementAddrCamel)
	}

	return strings.TrimSpace(e.ManagementAddr)
}

func (e UniFiPortEntry) ifIndex() int32 {
	if e.PortIdxCamel > 0 {
		return e.PortIdxCamel
	}

	return e.PortIdx
}

func (e UniFiPortEntry) connected() UniFiPortConnectedPeer {
	if strings.TrimSpace(e.ConnectedCamel.MAC) != "" ||
		strings.TrimSpace(e.ConnectedCamel.MACCamel) != "" ||
		strings.TrimSpace(e.ConnectedCamel.IP) != "" ||
		strings.TrimSpace(e.ConnectedCamel.IPCamel) != "" {
		return e.ConnectedCamel
	}

	return e.Connected
}

func (p UniFiPortConnectedPeer) mac() string {
	if strings.TrimSpace(p.MACCamel) != "" {
		return strings.TrimSpace(p.MACCamel)
	}

	return strings.TrimSpace(p.MAC)
}

func (p UniFiPortConnectedPeer) ip() string {
	if strings.TrimSpace(p.IPCamel) != "" {
		return strings.TrimSpace(p.IPCamel)
	}

	return strings.TrimSpace(p.IP)
}

func (p UniFiPortConnectedPeer) deviceID() string {
	switch {
	case strings.TrimSpace(p.DeviceID) != "":
		return strings.TrimSpace(p.DeviceID)
	case strings.TrimSpace(p.DeviceIDSnake) != "":
		return strings.TrimSpace(p.DeviceIDSnake)
	case strings.TrimSpace(p.RemoteID) != "":
		return strings.TrimSpace(p.RemoteID)
	case strings.TrimSpace(p.RemoteIDSnake) != "":
		return strings.TrimSpace(p.RemoteIDSnake)
	default:
		return strings.TrimSpace(p.ID)
	}
}
