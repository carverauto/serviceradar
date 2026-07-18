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
)

type UniFiSite struct {
	ID                string `json:"id"`
	InternalReference string `json:"internalReference"`
	Name              string `json:"name"`
}

// UniFiDevice represents a network device managed by a UniFi controller.
type UniFiDevice struct {
	ID         string          `json:"id"`
	IPAddress  string          `json:"ipAddress"`
	Name       string          `json:"name"`
	MAC        string          `json:"macAddress"`
	Features   []string        `json:"features"`
	Uplink     UniFiUplink     `json:"uplink"`
	Interfaces json.RawMessage `json:"interfaces"` // Use RawMessage to handle varying structures
}

// UniFiUplink captures multiple schema variants for uplink metadata.
type UniFiUplink struct {
	DeviceID      string `json:"deviceId"`
	DeviceIDSnake string `json:"device_id"`
	UpstreamID    string `json:"upstreamDeviceId"`
	UpstreamSnake string `json:"upstream_device_id"`

	LocalPortIdx      int32 `json:"localPortIdx"`
	LocalPortIdxSnake int32 `json:"local_port_idx"`
	PortIdx           int32 `json:"portIdx"`
	PortIdxSnake      int32 `json:"port_idx"`
	ParentPortIdx     int32 `json:"parentPortIdx"`
	ParentPortSnake   int32 `json:"parent_port_idx"`

	localPortIdxSet      bool
	localPortIdxSnakeSet bool
	portIdxSet           bool
	portIdxSnakeSet      bool
	parentPortIdxSet     bool
	parentPortSnakeSet   bool

	LocalPortName      string `json:"localPortName"`
	LocalPortNameSnake string `json:"local_port_name"`
	PortName           string `json:"portName"`
	PortNameSnake      string `json:"port_name"`
	ParentPortName     string `json:"parentPortName"`
	ParentPortNameSnk  string `json:"parent_port_name"`
}

// UniFiInterfaces represents the interfaces object for devices with ports
type UniFiInterfaces struct {
	Ports []struct {
		Idx          int    `json:"idx"`
		State        string `json:"state"`
		Connector    string `json:"connector"`
		MaxSpeedMbps int    `json:"maxSpeedMbps"`
		SpeedMbps    int    `json:"speedMbps"`
		PoE          struct {
			Standard string `json:"standard"`
			Type     int    `json:"type"`
			Enabled  bool   `json:"enabled"`
			State    string `json:"state"`
		} `json:"poe,omitempty"`
	} `json:"ports"`
}

// UniFiDeviceDetails represents detailed device information
type UniFiDeviceDetails struct {
	LLDPTable      []UniFiLLDPEntry `json:"lldp_table"`
	LLDPTableCamel []UniFiLLDPEntry `json:"lldpTable"`

	PortTable      []UniFiPortEntry `json:"port_table"`
	PortTableCamel []UniFiPortEntry `json:"portTable"`

	Interfaces UniFiInterfaces `json:"interfaces"`

	Uplink UniFiUplink `json:"uplink"`

	AdapterVersion string `json:"-"`
	AdapterShape   string `json:"-"`
}

type UniFiClient struct {
	ID             string            `json:"id"`
	Type           string            `json:"type"`
	Name           string            `json:"name"`
	MACAddress     string            `json:"macAddress"`
	IPAddress      string            `json:"ipAddress"`
	UplinkDeviceID string            `json:"uplinkDeviceId"`
	ConnectedAt    string            `json:"connectedAt"`
	Access         UniFiClientAccess `json:"access"`

	// Optional uplink switch/port detail for wired clients. The deployed
	// Integration v1 controllers omit these fields entirely, so consumers must
	// degrade to switch-level attachment when they are absent.
	UplinkDeviceMAC      string `json:"uplinkDeviceMac"`
	UplinkDeviceMACSnake string `json:"uplink_device_mac"`
	UplinkPortIdx        *int32 `json:"uplinkPortIdx"`
	UplinkPortIdxSnake   *int32 `json:"uplink_port_idx"`
}

type UniFiClientAccess struct {
	Type string `json:"type"`
}

type UniFiLLDPEntry struct {
	LocalPortIdx        int32  `json:"local_port_idx"`
	LocalPortIdxCamel   int32  `json:"localPortIdx"`
	LocalPortName       string `json:"local_port_name"`
	LocalPortNameCamel  string `json:"localPortName"`
	ChassisID           string `json:"chassis_id"`
	ChassisIDCamel      string `json:"chassisId"`
	PortID              string `json:"port_id"`
	PortIDCamel         string `json:"portId"`
	PortDescription     string `json:"port_description"`
	PortDescrCamel      string `json:"portDescription"`
	SystemName          string `json:"system_name"`
	SystemNameCamel     string `json:"systemName"`
	ManagementAddr      string `json:"management_address"`
	ManagementAddrCamel string `json:"managementAddr"`
}

type UniFiPortEntry struct {
	PortIdx        int32                  `json:"port_idx"`
	PortIdxCamel   int32                  `json:"portIdx"`
	Name           string                 `json:"name"`
	Connected      UniFiPortConnectedPeer `json:"connected_device"`
	ConnectedCamel UniFiPortConnectedPeer `json:"connectedDevice"`
}

type UniFiPortConnectedPeer struct {
	MAC      string `json:"mac"`
	MACCamel string `json:"macAddress"`
	Name     string `json:"name"`
	IP       string `json:"ip"`
	IPCamel  string `json:"ipAddress"`

	DeviceID      string `json:"deviceId"`
	DeviceIDSnake string `json:"device_id"`
	RemoteID      string `json:"remoteDeviceId"`
	RemoteIDSnake string `json:"remote_device_id"`
	ID            string `json:"id"`
}
