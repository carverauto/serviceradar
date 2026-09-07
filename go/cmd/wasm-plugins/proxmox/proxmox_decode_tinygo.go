//go:build tinygo

package main

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

func getJSON[T any](cfg Config, target Target, token, path string, out *T) error {
	resp, err := proxmoxHTTP.Do(sdk.HTTPRequest{
		Method:             http.MethodGet,
		URL:                strings.TrimRight(target.BaseURL, "/") + path,
		Headers:            map[string]string{"Authorization": token, "Accept": "application/json"},
		TimeoutMS:          cfg.TimeoutMS,
		InsecureSkipVerify: false,
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
	root := gjson.ParseBytes(body)
	data := root.Get("data")

	switch typed := any(out).(type) {
	case *proxmoxVersionResponse:
		typed.Data = proxmoxVersion{
			Version: data.Get("version").String(),
			Release: data.Get("release").String(),
			RepoID:  data.Get("repoid").String(),
		}
	case *proxmoxNodesResponse:
		typed.Data = parseProxmoxNodes(data)
	case *proxmoxResourcesResponse:
		typed.Data = parseProxmoxResources(data)
	case *proxmoxClusterStatusResponse:
		typed.Data = parseProxmoxClusterNodes(data)
	case *proxmoxNodeStatusResponse:
		typed.Data = proxmoxNodeStatus{Wait: data.Get("wait").Float()}
	case *proxmoxStorageResponse:
		typed.Data = parseProxmoxStorage(data)
	case *proxmoxNetworkResponse:
		typed.Data = parseProxmoxNetwork(data)
	case *proxmoxDiskResponse:
		typed.Data = parseProxmoxDisks(data)
	case *proxmoxCephStatusResponse:
		health := data.Get("health").String()
		if healthObject := data.Get("health"); healthObject.IsObject() {
			health = firstNonEmpty(healthObject.Get("status").String(), health)
		}
		typed.Data = proxmoxCephStatus{
			Health:        health,
			Status:        data.Get("status").String(),
			OverallStatus: data.Get("overall_status").String(),
		}
	case *proxmoxStringMapResponse:
		typed.Data = jsonObjectStringMap(data)
	case *proxmoxGuestAgentNetworkResponse:
		typed.Data.Result = parseGuestAgentInterfaces(data.Get("result"))
	case *proxmoxGuestAgentFSInfoResponse:
		typed.Data.Result = parseGuestFilesystems(data.Get("result"))
	case *proxmoxLXCInterfacesResponse:
		typed.Data = parseLXCInterfaces(data)
	default:
		return fmt.Errorf("unsupported proxmox response type")
	}

	return nil
}

func parseProxmoxNodes(array gjson.Result) []proxmoxNode {
	items := array.Array()
	out := make([]proxmoxNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNode{
			Node:   item.Get("node").String(),
			Status: item.Get("status").String(),
			IP:     item.Get("ip").String(),
			CPU:    item.Get("cpu").Float(),
			MaxCPU: item.Get("maxcpu").Float(),
			Mem:    item.Get("mem").Float(),
			MaxMem: item.Get("maxmem").Float(),
			Uptime: item.Get("uptime").Float(),
		})
	}

	return out
}

func parseProxmoxResources(array gjson.Result) []proxmoxResource {
	items := array.Array()
	out := make([]proxmoxResource, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxResource{
			ID:      item.Get("id").String(),
			Node:    item.Get("node").String(),
			Name:    item.Get("name").String(),
			Type:    item.Get("type").String(),
			Status:  item.Get("status").String(),
			VMID:    int(item.Get("vmid").Int()),
			CPU:     item.Get("cpu").Float(),
			MaxCPU:  item.Get("maxcpu").Float(),
			Mem:     item.Get("mem").Float(),
			MaxMem:  item.Get("maxmem").Float(),
			Disk:    item.Get("disk").Float(),
			MaxDisk: item.Get("maxdisk").Float(),
			Uptime:  item.Get("uptime").Float(),
		})
	}

	return out
}

func parseProxmoxClusterNodes(array gjson.Result) []proxmoxClusterNode {
	items := array.Array()
	out := make([]proxmoxClusterNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxClusterNode{
			ID:      item.Get("id").String(),
			Name:    item.Get("name").String(),
			Type:    item.Get("type").String(),
			NodeID:  int(item.Get("nodeid").Int()),
			Nodes:   int(item.Get("nodes").Int()),
			Quorate: int(item.Get("quorate").Int()),
			IP:      item.Get("ip").String(),
			Local:   int(item.Get("local").Int()),
			Online:  int(item.Get("online").Int()),
		})
	}

	return out
}

func parseProxmoxStorage(array gjson.Result) []proxmoxStorage {
	items := array.Array()
	out := make([]proxmoxStorage, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxStorage{
			Storage: item.Get("storage").String(),
			Type:    item.Get("type").String(),
			Content: item.Get("content").String(),
			Used:    item.Get("used").Float(),
			Avail:   item.Get("avail").Float(),
			Total:   item.Get("total").Float(),
		})
	}

	return out
}

func parseProxmoxNetwork(array gjson.Result) []proxmoxNetworkInterface {
	items := array.Array()
	out := make([]proxmoxNetworkInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNetworkInterface{
			Iface:       item.Get("iface").String(),
			Type:        item.Get("type").String(),
			Method:      item.Get("method").String(),
			Method6:     item.Get("method6").String(),
			MACAddress:  item.Get("hwaddr").String(),
			Address:     item.Get("address").String(),
			Netmask:     item.Get("netmask").String(),
			Gateway:     item.Get("gateway").String(),
			CIDR:        item.Get("cidr").String(),
			BridgePorts: item.Get("bridge-ports").String(),
			Families:    jsonStringArrayValue(item.Get("families")),
		})
	}

	return out
}

func parseProxmoxDisks(array gjson.Result) []proxmoxDisk {
	items := array.Array()
	out := make([]proxmoxDisk, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxDisk{
			DevPath: item.Get("devpath").String(),
			ByID:    item.Get("by_id_link").String(),
			Type:    item.Get("type").String(),
			Model:   item.Get("model").String(),
			Vendor:  item.Get("vendor").String(),
			Used:    item.Get("used").String(),
			Health:  item.Get("health").String(),
			Size:    item.Get("size").Float(),
		})
	}

	return out
}

func parseGuestAgentInterfaces(array gjson.Result) []proxmoxGuestAgentInterface {
	items := array.Array()
	out := make([]proxmoxGuestAgentInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentInterface{
			Name:            item.Get("name").String(),
			HardwareAddress: item.Get("hardware-address").String(),
			IPAddresses:     parseGuestAgentIPAddresses(item.Get("ip-addresses")),
		})
	}

	return out
}

func parseGuestAgentIPAddresses(array gjson.Result) []proxmoxGuestAgentIPAddress {
	items := array.Array()
	out := make([]proxmoxGuestAgentIPAddress, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentIPAddress{
			IPAddress:     item.Get("ip-address").String(),
			IPAddressType: item.Get("ip-address-type").String(),
			Prefix:        int(item.Get("prefix").Int()),
		})
	}

	return out
}

func parseGuestFilesystems(array gjson.Result) []proxmoxGuestFilesystem {
	items := array.Array()
	out := make([]proxmoxGuestFilesystem, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestFilesystem{
			Name:       item.Get("name").String(),
			Mountpoint: item.Get("mountpoint").String(),
			Type:       item.Get("type").String(),
			TotalBytes: item.Get("total-bytes").Float(),
			UsedBytes:  item.Get("used-bytes").Float(),
		})
	}

	return out
}

func parseLXCInterfaces(array gjson.Result) []proxmoxLXCInterface {
	items := array.Array()
	out := make([]proxmoxLXCInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxLXCInterface{
			Name:       item.Get("name").String(),
			Hardware:   item.Get("hardware").String(),
			MACAddress: item.Get("hwaddr").String(),
			Inet:       item.Get("inet").String(),
			Inet6:      item.Get("inet6").String(),
		})
	}

	return out
}

func jsonObjectStringMap(object gjson.Result) map[string]string {
	if !object.IsObject() {
		return nil
	}

	out := map[string]string{}
	object.ForEach(func(key, value gjson.Result) bool {
		if value.IsObject() || value.IsArray() || value.Type == gjson.Null {
			return true
		}
		out[key.String()] = value.String()
		return true
	})
	if len(out) == 0 {
		return nil
	}

	return out
}

func jsonStringArrayValue(array gjson.Result) []string {
	if !array.IsArray() {
		return nil
	}

	values := make([]string, 0)
	array.ForEach(func(_key, value gjson.Result) bool {
		if value.Type != gjson.Null {
			values = append(values, value.String())
		}
		return true
	})
	if len(values) == 0 {
		return nil
	}

	return values
}

func responseBodySuffix(body []byte) string {
	bodyText := strings.Join(strings.Fields(string(body)), " ")
	bodyText = sanitizeSecretString(bodyText)
	if bodyText == "" {
		return ""
	}
	bodyText = truncateString(bodyText, 300)

	return ": " + bodyText
}
