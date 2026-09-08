/*
 * Copyright 2026 Carver Automation Corporation.
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

package armis

import (
	"bytes"
	"encoding/json"
	"net"
	"sort"
	"strings"
	"time"
)

type device struct {
	ID                int                        `json:"id"`
	DeviceID          int                        `json:"device_id"`
	IPAddress         string                     `json:"ipAddress"`
	IPv4Addresses     []string                   `json:"ipv4_addresses"`
	IPv6Addresses     []string                   `json:"ipv6_addresses"`
	MacAddress        string                     `json:"macAddress"`
	MacAddresses      []string                   `json:"mac_addresses"`
	Name              string                     `json:"name"`
	Names             stringList                 `json:"names"`
	Display           string                     `json:"display"`
	Type              string                     `json:"type"`
	Category          string                     `json:"category"`
	Manufacturer      string                     `json:"manufacturer"`
	Brand             string                     `json:"brand"`
	Model             string                     `json:"model"`
	OperatingSystem   string                     `json:"operatingSystem"`
	OSName            string                     `json:"os_name"`
	OSVersion         string                     `json:"os_version"`
	FirstSeen         time.Time                  `json:"firstSeen"`
	FirstSeenSnake    time.Time                  `json:"first_seen"`
	LastSeen          time.Time                  `json:"lastSeen"`
	LastSeenSnake     time.Time                  `json:"last_seen"`
	RiskLevel         int                        `json:"riskLevel"`
	RiskLevelSnake    int                        `json:"risk_level"`
	Boundaries        interface{}                `json:"boundaries"`
	Tags              []string                   `json:"tags"`
	NetworkInterfaces []map[string]interface{}   `json:"network_interfaces"`
	PurdueLevel       *float64                   `json:"purdue_level"`
	SerialNumbers     []string                   `json:"serial_numbers"`
	Site              map[string]interface{}     `json:"site"`
	Visibility        string                     `json:"visibility"`
	RawFields         map[string]json.RawMessage `json:"-"`
}

func (d *device) UnmarshalJSON(data []byte) error {
	type deviceAlias device

	var decoded deviceAlias
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}

	*d = device(decoded)

	var rawFields map[string]json.RawMessage
	if err := json.Unmarshal(data, &rawFields); err == nil {
		d.RawFields = rawFields
	}

	if len(d.NetworkInterfaces) == 0 {
		for _, key := range []string{"networkInterfaces", "interfaces", "networkInterface"} {
			if raw := d.rawField(key); len(raw) > 0 {
				_ = json.Unmarshal(raw, &d.NetworkInterfaces)
				if len(d.NetworkInterfaces) > 0 {
					break
				}
			}
		}
	}

	return nil
}

func (d device) rawField(key string) json.RawMessage {
	if len(d.RawFields) == 0 {
		return nil
	}

	if raw, ok := d.RawFields[key]; ok {
		return raw
	}

	normalized := normalizeMetadataFieldName(key)
	for rawKey, raw := range d.RawFields {
		if normalizeMetadataFieldName(rawKey) == normalized {
			return raw
		}
	}

	return nil
}

func (d *device) setRawField(key string, raw json.RawMessage) {
	key = strings.TrimSpace(key)
	if key == "" || len(bytes.TrimSpace(raw)) == 0 {
		return
	}

	if d.RawFields == nil {
		d.RawFields = make(map[string]json.RawMessage)
	}

	d.RawFields[key] = append(json.RawMessage(nil), raw...)
}

type stringList []string

func (l *stringList) UnmarshalJSON(data []byte) error {
	if strings.TrimSpace(string(data)) == "null" {
		*l = nil
		return nil
	}

	var values []string
	if err := json.Unmarshal(data, &values); err == nil {
		*l = values
		return nil
	}

	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}

	value = strings.TrimSpace(value)
	if value == "" {
		*l = nil
		return nil
	}

	*l = stringList{value}

	return nil
}

type searchResponse struct {
	Data struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []device    `json:"results"`
		Total   int         `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

type tokenResponse struct {
	Data struct {
		AccessToken string `json:"access_token"`
	} `json:"data"`
	Success bool `json:"success"`
}

func (d device) effectiveID() int {
	if d.DeviceID > 0 {
		return d.DeviceID
	}
	return d.ID
}

func (d device) effectiveRiskLevel() int {
	if d.RiskLevelSnake > 0 {
		return d.RiskLevelSnake
	}
	return d.RiskLevel
}

func (d device) effectiveFirstSeen() time.Time {
	if !d.FirstSeenSnake.IsZero() {
		return d.FirstSeenSnake
	}
	return d.FirstSeen
}

func (d device) effectiveLastSeen() time.Time {
	if !d.LastSeenSnake.IsZero() {
		return d.LastSeenSnake
	}
	return d.LastSeen
}

func (d device) primaryIP() string {
	if value := strings.TrimSpace(d.IPAddress); value != "" {
		return value
	}
	for _, value := range d.IPv4Addresses {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	for _, value := range d.IPv6Addresses {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

// rawMACValues joins the comma-separated macAddress field and the
// mac_addresses list into a single comma-separated value. The result is raw
// API data: the generic runtime normalization step validates each entry,
// picks the primary MAC, and drops invalid values.
func (d device) rawMACValues() string {
	values := make([]string, 0, 1+len(d.MacAddresses))
	if value := strings.TrimSpace(d.MacAddress); value != "" {
		values = append(values, value)
	}
	for _, value := range d.MacAddresses {
		if value = strings.TrimSpace(value); value != "" {
			values = append(values, value)
		}
	}
	return strings.Join(values, ",")
}

func (d device) primaryName() string {
	if value := firstNonEmpty(d.Display, d.Name); value != "" {
		return value
	}
	for _, value := range d.Names {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func filterDevices(devices []device, blacklist []string) []device {
	cidrs := make([]*net.IPNet, 0, len(blacklist))
	for _, raw := range blacklist {
		_, network, err := net.ParseCIDR(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		cidrs = append(cidrs, network)
	}

	filtered := make([]device, 0, len(devices))
	for _, item := range devices {
		rawIP := item.primaryIP()
		ips := splitDeviceIPs(rawIP)
		if len(ips) == 0 {
			if rawIP == "" {
				filtered = append(filtered, item)
			}
			continue
		}

		for _, ip := range ips {
			if ipBlacklisted(ip, cidrs) {
				continue
			}

			normalized := item
			normalized.IPAddress = ip
			filtered = append(filtered, normalized)
			break
		}
	}

	return filtered
}

func splitDeviceIPs(value string) []string {
	fields := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == ';' || r == '\n' || r == '\t' || r == ' '
	})
	ips := make([]string, 0, len(fields))

	for _, field := range fields {
		candidate := strings.TrimSpace(field)
		if candidate == "" {
			continue
		}

		if ip := net.ParseIP(candidate); ip != nil {
			ips = append(ips, ip.String())
			continue
		}

		if ip, _, err := net.ParseCIDR(candidate); err == nil {
			ips = append(ips, ip.String())
		}
	}

	return ips
}

func ipBlacklisted(value string, cidrs []*net.IPNet) bool {
	if len(cidrs) == 0 {
		return false
	}

	ip := net.ParseIP(value)
	if ip == nil {
		return false
	}

	for _, network := range cidrs {
		if network.Contains(ip) {
			return true
		}
	}

	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func boundaryNames(value interface{}) []string {
	if value == nil {
		return nil
	}

	if text, ok := value.(string); ok {
		var decoded interface{}
		if err := json.Unmarshal([]byte(text), &decoded); err == nil {
			return boundaryNames(decoded)
		}
		return nil
	}

	var names []string
	switch typed := value.(type) {
	case []interface{}:
		for _, item := range typed {
			names = append(names, boundaryNames(item)...)
		}
	case []map[string]interface{}:
		for _, item := range typed {
			names = append(names, boundaryNames(item)...)
		}
	case map[string]interface{}:
		if name, ok := typed["name"].(string); ok && strings.TrimSpace(name) != "" {
			names = append(names, strings.TrimSpace(name))
		}
	}

	return uniqueStrings(names)
}

func sortedMapKeys(value map[string]interface{}) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func compactJSONValue(value interface{}) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return strings.TrimSpace(text)
	}
	data, err := json.Marshal(value)
	if err != nil || string(data) == "null" || string(data) == "{}" || string(data) == "[]" {
		return ""
	}
	return string(data)
}
