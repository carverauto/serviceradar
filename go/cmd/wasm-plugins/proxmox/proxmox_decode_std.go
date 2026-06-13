//go:build !tinygo

package main

import (
	"encoding/json"
	"strings"
)

func decodeProxmoxJSON[T any](body []byte, out *T) error {
	return json.Unmarshal(body, out)
}

func (iface *proxmoxNetworkInterface) UnmarshalJSON(body []byte) error {
	var raw struct {
		Iface       string   `json:"iface"`
		Type        string   `json:"type"`
		Method      string   `json:"method"`
		Method6     string   `json:"method6"`
		HWAddr      string   `json:"hwaddr"`
		MACAddress  string   `json:"mac_address"`
		Address     string   `json:"address"`
		Netmask     string   `json:"netmask"`
		Gateway     string   `json:"gateway"`
		CIDR        string   `json:"cidr"`
		BridgePorts string   `json:"bridge-ports"`
		Families    []string `json:"families"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return err
	}

	*iface = proxmoxNetworkInterface{
		Iface:       raw.Iface,
		Type:        raw.Type,
		Method:      raw.Method,
		Method6:     raw.Method6,
		MACAddress:  firstNonEmpty(raw.HWAddr, raw.MACAddress),
		Address:     raw.Address,
		Netmask:     raw.Netmask,
		Gateway:     raw.Gateway,
		CIDR:        raw.CIDR,
		BridgePorts: raw.BridgePorts,
		Families:    raw.Families,
	}

	return nil
}

func (status *proxmoxCephStatus) UnmarshalJSON(body []byte) error {
	var raw struct {
		Health        json.RawMessage `json:"health"`
		Status        string          `json:"status"`
		OverallStatus string          `json:"overall_status"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return err
	}

	status.Status = raw.Status
	status.OverallStatus = raw.OverallStatus
	if len(raw.Health) == 0 || string(raw.Health) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw.Health, &status.Health); err == nil {
		return nil
	}

	var healthObject struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(raw.Health, &healthObject); err != nil {
		return err
	}
	status.Health = healthObject.Status

	return nil
}

func (resp *proxmoxStringMapResponse) UnmarshalJSON(body []byte) error {
	var raw struct {
		Data map[string]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return err
	}
	if len(raw.Data) == 0 {
		return nil
	}

	resp.Data = make(map[string]string, len(raw.Data))
	for key, value := range raw.Data {
		var text string
		if err := json.Unmarshal(value, &text); err == nil {
			resp.Data[key] = text
			continue
		}

		trimmed := strings.TrimSpace(string(value))
		if trimmed == "" || trimmed == "null" || strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
			continue
		}
		resp.Data[key] = strings.Trim(trimmed, ` "`)
	}
	if len(resp.Data) == 0 {
		resp.Data = nil
	}

	return nil
}
