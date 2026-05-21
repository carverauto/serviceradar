//go:build tinygo

package main

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func getJSON[T any](cfg Config, target Target, token, path string, out *T) error {
	resp, err := proxmoxHTTP.Do(sdk.HTTPRequest{
		Method:             http.MethodGet,
		URL:                strings.TrimRight(target.BaseURL, "/") + path,
		Headers:            map[string]string{"Authorization": token, "Accept": "application/json"},
		TimeoutMS:          cfg.TimeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	})
	if err != nil {
		return err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return fmt.Errorf("HTTP %d%s", resp.Status, responseBodySuffix(resp.Body))
	}
	if err := decodeProxmoxJSON(resp.Body, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	return nil
}

func decodeProxmoxJSON[T any](body []byte, out *T) error {
	raw := string(body)

	switch typed := any(out).(type) {
	case *proxmoxVersionResponse:
		data := jsonDataObject(raw)
		typed.Data = proxmoxVersion{
			Version: jsonStringValue(data, "version"),
			Release: jsonStringValue(data, "release"),
			RepoID:  jsonStringValue(data, "repoid"),
		}
	case *proxmoxNodesResponse:
		typed.Data = parseProxmoxNodes(jsonDataArray(raw))
	case *proxmoxResourcesResponse:
		typed.Data = parseProxmoxResources(jsonDataArray(raw))
	case *proxmoxClusterStatusResponse:
		typed.Data = parseProxmoxClusterNodes(jsonDataArray(raw))
	case *proxmoxNodeStatusResponse:
		data := jsonDataObject(raw)
		typed.Data = proxmoxNodeStatus{Wait: jsonFloatValue(data, "wait")}
	case *proxmoxStorageResponse:
		typed.Data = parseProxmoxStorage(jsonDataArray(raw))
	case *proxmoxNetworkResponse:
		typed.Data = parseProxmoxNetwork(jsonDataArray(raw))
	case *proxmoxDiskResponse:
		typed.Data = parseProxmoxDisks(jsonDataArray(raw))
	case *proxmoxCephStatusResponse:
		data := jsonDataObject(raw)
		health := jsonStringValue(data, "health")
		if healthObject := jsonObjectValue(data, "health"); healthObject != "" {
			health = firstNonEmpty(jsonStringValue(healthObject, "status"), health)
		}
		typed.Data = proxmoxCephStatus{
			Health:        health,
			Status:        jsonStringValue(data, "status"),
			OverallStatus: jsonStringValue(data, "overall_status"),
		}
	case *proxmoxStringMapResponse:
		typed.Data = jsonObjectStringMap(jsonDataObject(raw))
	case *proxmoxGuestAgentNetworkResponse:
		typed.Data.Result = parseGuestAgentInterfaces(jsonArrayValue(jsonDataObject(raw), "result"))
	case *proxmoxGuestAgentFSInfoResponse:
		typed.Data.Result = parseGuestFilesystems(jsonArrayValue(jsonDataObject(raw), "result"))
	case *proxmoxLXCInterfacesResponse:
		typed.Data = parseLXCInterfaces(jsonDataArray(raw))
	default:
		return fmt.Errorf("unsupported proxmox response type")
	}

	return nil
}

func jsonDataArray(raw string) string {
	return jsonArrayValue(raw, "data")
}

func jsonDataObject(raw string) string {
	return jsonObjectValue(raw, "data")
}

func jsonArrayValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end || raw[start] != '[' {
		return ""
	}

	return raw[start:end]
}

func jsonObjectValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end || raw[start] != '{' {
		return ""
	}

	return raw[start:end]
}

func parseProxmoxNodes(array string) []proxmoxNode {
	items := rawJSONObjectList(array)
	out := make([]proxmoxNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNode{
			Node:   jsonStringValue(item, "node"),
			Status: jsonStringValue(item, "status"),
			IP:     jsonStringValue(item, "ip"),
			CPU:    jsonFloatValue(item, "cpu"),
			MaxCPU: jsonFloatValue(item, "maxcpu"),
			Mem:    jsonFloatValue(item, "mem"),
			MaxMem: jsonFloatValue(item, "maxmem"),
			Uptime: jsonFloatValue(item, "uptime"),
		})
	}

	return out
}

func parseProxmoxResources(array string) []proxmoxResource {
	items := rawJSONObjectList(array)
	out := make([]proxmoxResource, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxResource{
			ID:      jsonStringValue(item, "id"),
			Node:    jsonStringValue(item, "node"),
			Name:    jsonStringValue(item, "name"),
			Type:    jsonStringValue(item, "type"),
			Status:  jsonStringValue(item, "status"),
			VMID:    jsonIntValue(item, "vmid"),
			CPU:     jsonFloatValue(item, "cpu"),
			MaxCPU:  jsonFloatValue(item, "maxcpu"),
			Mem:     jsonFloatValue(item, "mem"),
			MaxMem:  jsonFloatValue(item, "maxmem"),
			Disk:    jsonFloatValue(item, "disk"),
			MaxDisk: jsonFloatValue(item, "maxdisk"),
			Uptime:  jsonFloatValue(item, "uptime"),
		})
	}

	return out
}

func parseProxmoxClusterNodes(array string) []proxmoxClusterNode {
	items := rawJSONObjectList(array)
	out := make([]proxmoxClusterNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxClusterNode{
			ID:      jsonStringValue(item, "id"),
			Name:    jsonStringValue(item, "name"),
			Type:    jsonStringValue(item, "type"),
			NodeID:  jsonIntValue(item, "nodeid"),
			Nodes:   jsonIntValue(item, "nodes"),
			Quorate: jsonIntValue(item, "quorate"),
			IP:      jsonStringValue(item, "ip"),
			Local:   jsonIntValue(item, "local"),
			Online:  jsonIntValue(item, "online"),
		})
	}

	return out
}

func parseProxmoxStorage(array string) []proxmoxStorage {
	items := rawJSONObjectList(array)
	out := make([]proxmoxStorage, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxStorage{
			Storage: jsonStringValue(item, "storage"),
			Type:    jsonStringValue(item, "type"),
			Content: jsonStringValue(item, "content"),
			Used:    jsonFloatValue(item, "used"),
			Avail:   jsonFloatValue(item, "avail"),
			Total:   jsonFloatValue(item, "total"),
		})
	}

	return out
}

func parseProxmoxNetwork(array string) []proxmoxNetworkInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxNetworkInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNetworkInterface{
			Iface:       jsonStringValue(item, "iface"),
			Type:        jsonStringValue(item, "type"),
			Method:      jsonStringValue(item, "method"),
			Method6:     jsonStringValue(item, "method6"),
			Address:     jsonStringValue(item, "address"),
			Netmask:     jsonStringValue(item, "netmask"),
			Gateway:     jsonStringValue(item, "gateway"),
			CIDR:        jsonStringValue(item, "cidr"),
			BridgePorts: jsonStringValue(item, "bridge-ports"),
			Families:    jsonStringArrayValue(item, "families"),
		})
	}

	return out
}

func parseProxmoxDisks(array string) []proxmoxDisk {
	items := rawJSONObjectList(array)
	out := make([]proxmoxDisk, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxDisk{
			DevPath: jsonStringValue(item, "devpath"),
			ByID:    jsonStringValue(item, "by_id_link"),
			Type:    jsonStringValue(item, "type"),
			Model:   jsonStringValue(item, "model"),
			Vendor:  jsonStringValue(item, "vendor"),
			Used:    jsonStringValue(item, "used"),
			Health:  jsonStringValue(item, "health"),
			Size:    jsonFloatValue(item, "size"),
		})
	}

	return out
}

func parseGuestAgentInterfaces(array string) []proxmoxGuestAgentInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestAgentInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentInterface{
			Name:            jsonStringValue(item, "name"),
			HardwareAddress: jsonStringValue(item, "hardware-address"),
			IPAddresses:     parseGuestAgentIPAddresses(jsonArrayValue(item, "ip-addresses")),
		})
	}

	return out
}

func parseGuestAgentIPAddresses(array string) []proxmoxGuestAgentIPAddress {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestAgentIPAddress, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentIPAddress{
			IPAddress:     jsonStringValue(item, "ip-address"),
			IPAddressType: jsonStringValue(item, "ip-address-type"),
			Prefix:        jsonIntValue(item, "prefix"),
		})
	}

	return out
}

func parseGuestFilesystems(array string) []proxmoxGuestFilesystem {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestFilesystem, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestFilesystem{
			Name:       jsonStringValue(item, "name"),
			Mountpoint: jsonStringValue(item, "mountpoint"),
			Type:       jsonStringValue(item, "type"),
			TotalBytes: jsonFloatValue(item, "total-bytes"),
			UsedBytes:  jsonFloatValue(item, "used-bytes"),
		})
	}

	return out
}

func parseLXCInterfaces(array string) []proxmoxLXCInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxLXCInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxLXCInterface{
			Name:       jsonStringValue(item, "name"),
			Hardware:   jsonStringValue(item, "hardware"),
			MACAddress: jsonStringValue(item, "hwaddr"),
			Inet:       jsonStringValue(item, "inet"),
			Inet6:      jsonStringValue(item, "inet6"),
		})
	}

	return out
}

func jsonObjectStringMap(object string) map[string]string {
	object = strings.TrimSpace(object)
	if len(object) < 2 || object[0] != '{' {
		return nil
	}
	out := map[string]string{}
	for i := 1; i < len(object)-1; {
		i = skipJSONWhitespace(object, i)
		if i >= len(object)-1 || object[i] == '}' {
			break
		}
		if object[i] != '"' {
			i++
			continue
		}
		keyEnd := jsonStringEnd(object, i)
		if keyEnd < 0 {
			break
		}
		key, err := strconv.Unquote(object[i : keyEnd+1])
		if err != nil {
			break
		}
		colon := skipJSONWhitespace(object, keyEnd+1)
		if colon >= len(object) || object[colon] != ':' {
			i = keyEnd + 1
			continue
		}
		valueStart := skipJSONWhitespace(object, colon+1)
		valueEnd := jsonValueEnd(object, valueStart)
		if valueEnd < 0 {
			break
		}
		value := strings.TrimSpace(object[valueStart:valueEnd])
		if strings.HasPrefix(value, `"`) {
			if unquoted, err := strconv.Unquote(value); err == nil {
				out[key] = unquoted
			}
		} else if value != "null" && value != "" && !strings.HasPrefix(value, "{") && !strings.HasPrefix(value, "[") {
			out[key] = strings.Trim(value, ` "`)
		}
		i = valueEnd + 1
	}
	if len(out) == 0 {
		return nil
	}

	return out
}

func responseBodySuffix(body []byte) string {
	bodyText := strings.Join(strings.Fields(string(body)), " ")
	bodyText = sanitizeSecretString(bodyText)
	if bodyText == "" {
		return ""
	}
	if len(bodyText) > 300 {
		bodyText = bodyText[:300] + "..."
	}

	return ": " + bodyText
}
