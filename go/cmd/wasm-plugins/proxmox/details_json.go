package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

func marshalProxmoxDetails(details proxmoxDetails) ([]byte, error) {
	var b strings.Builder
	appendProxmoxDetailsJSON(&b, details)

	return []byte(b.String()), nil
}

func appendProxmoxDetailsJSON(b *strings.Builder, details proxmoxDetails) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "schema", details.Schema)
	appendFieldName(b, &first, "targets")
	appendTargetsJSON(b, details.Targets)
	appendFieldName(b, &first, "summary")
	appendCheckSummaryJSON(b, details.Summary)
	if !emptyResourceSummary(details.ResourceSummary) {
		appendFieldName(b, &first, "resource_summary")
		appendResourceSummaryJSON(b, details.ResourceSummary)
	}
	if len(details.Errors) > 0 {
		appendFieldName(b, &first, "errors")
		appendStringMapJSON(b, details.Errors)
	}
	b.WriteByte('}')
}

func appendTargetsJSON(b *strings.Builder, targets []proxmoxTarget) {
	b.WriteByte('[')
	for i, target := range targets {
		if i > 0 {
			b.WriteByte(',')
		}
		appendTargetJSON(b, target)
	}
	b.WriteByte(']')
}

func appendTargetJSON(b *strings.Builder, target proxmoxTarget) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "base_url", target.BaseURL)
	if target.Version != nil {
		appendFieldName(b, &first, "version")
		appendVersionJSON(b, *target.Version)
	}
	if len(target.Cluster) > 0 {
		appendFieldName(b, &first, "cluster")
		appendClusterJSON(b, target.Cluster)
	}
	appendFieldName(b, &first, "nodes")
	appendNodesJSON(b, target.Nodes)
	if len(target.Guests) > 0 {
		appendFieldName(b, &first, "guests")
		appendGuestsJSON(b, target.Guests)
	}
	if !emptyResourceSummary(target.Summary) {
		appendFieldName(b, &first, "resource_summary")
		appendResourceSummaryJSON(b, target.Summary)
	}
	if len(target.Warnings) > 0 {
		appendFieldName(b, &first, "warnings")
		appendStringMapJSON(b, target.Warnings)
	}
	if len(target.Meta) > 0 {
		appendFieldName(b, &first, "metadata")
		appendStringMapJSON(b, target.Meta)
	}
	b.WriteByte('}')
}

func appendVersionJSON(b *strings.Builder, version proxmoxVersion) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "version", version.Version)
	appendStringField(b, &first, "release", version.Release)
	appendStringField(b, &first, "repoid", version.RepoID)
	b.WriteByte('}')
}

func appendClusterJSON(b *strings.Builder, nodes []proxmoxClusterNode) {
	b.WriteByte('[')
	for i, node := range nodes {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "id", node.ID)
		appendStringField(b, &first, "name", node.Name)
		appendStringField(b, &first, "type", node.Type)
		appendIntField(b, &first, "nodeid", node.NodeID)
		appendIntField(b, &first, "nodes", node.Nodes)
		appendIntField(b, &first, "quorate", node.Quorate)
		appendStringField(b, &first, "ip", node.IP)
		appendIntField(b, &first, "local", node.Local)
		appendIntField(b, &first, "online", node.Online)
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendNodesJSON(b *strings.Builder, nodes []proxmoxNode) {
	b.WriteByte('[')
	for i, node := range nodes {
		if i > 0 {
			b.WriteByte(',')
		}
		appendNodeJSON(b, node)
	}
	b.WriteByte(']')
}

func appendNodeJSON(b *strings.Builder, node proxmoxNode) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "node", node.Node)
	appendStringField(b, &first, "status", node.Status)
	appendStringField(b, &first, "ip", node.IP)
	appendFloatField(b, &first, "cpu", node.CPU)
	appendFloatField(b, &first, "maxcpu", node.MaxCPU)
	appendFloatField(b, &first, "mem", node.Mem)
	appendFloatField(b, &first, "maxmem", node.MaxMem)
	appendFloatField(b, &first, "uptime", node.Uptime)
	if node.RuntimeState.Wait != 0 {
		appendFieldName(b, &first, "runtime_status")
		b.WriteString(`{"wait":`)
		b.WriteString(strconv.FormatFloat(node.RuntimeState.Wait, 'f', -1, 64))
		b.WriteByte('}')
	}
	if len(node.Storage) > 0 {
		appendFieldName(b, &first, "storage")
		appendStorageJSON(b, node.Storage)
	}
	if len(node.Network) > 0 {
		appendFieldName(b, &first, "network")
		appendNetworkJSON(b, node.Network)
	}
	if len(node.Disks) > 0 {
		appendFieldName(b, &first, "disks")
		appendDisksJSON(b, node.Disks)
	}
	if node.Ceph != nil && !node.Ceph.empty() {
		appendFieldName(b, &first, "ceph")
		b.WriteString(`{"health":`)
		b.WriteString(strconv.Quote(node.Ceph.Health))
		b.WriteByte('}')
	}
	b.WriteByte('}')
}

func appendStorageJSON(b *strings.Builder, values []proxmoxStorage) {
	b.WriteByte('[')
	for i, value := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "storage", value.Storage)
		appendStringField(b, &first, "type", value.Type)
		appendStringField(b, &first, "content", value.Content)
		appendFloatField(b, &first, "used", value.Used)
		appendFloatField(b, &first, "avail", value.Avail)
		appendFloatField(b, &first, "total", value.Total)
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendNetworkJSON(b *strings.Builder, values []proxmoxNetworkInterface) {
	b.WriteByte('[')
	for i, value := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "iface", value.Iface)
		appendStringField(b, &first, "type", value.Type)
		appendStringField(b, &first, "method", value.Method)
		appendStringField(b, &first, "method6", value.Method6)
		appendStringField(b, &first, "mac_address", value.MACAddress)
		appendStringField(b, &first, "address", value.Address)
		appendStringField(b, &first, "netmask", value.Netmask)
		appendStringField(b, &first, "gateway", value.Gateway)
		appendStringField(b, &first, "cidr", value.CIDR)
		appendStringField(b, &first, "bridge-ports", value.BridgePorts)
		if len(value.Families) > 0 {
			appendFieldName(b, &first, "families")
			appendStringSliceJSON(b, value.Families)
		}
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendDisksJSON(b *strings.Builder, values []proxmoxDisk) {
	b.WriteByte('[')
	for i, value := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "devpath", value.DevPath)
		appendStringField(b, &first, "by_id_link", value.ByID)
		appendStringField(b, &first, "type", value.Type)
		appendStringField(b, &first, "model", value.Model)
		appendStringField(b, &first, "vendor", value.Vendor)
		appendStringField(b, &first, "used", value.Used)
		appendStringField(b, &first, "health", value.Health)
		appendFloatField(b, &first, "size", value.Size)
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendGuestsJSON(b *strings.Builder, guests []proxmoxGuest) {
	b.WriteByte('[')
	for i, guest := range guests {
		if i > 0 {
			b.WriteByte(',')
		}
		appendGuestJSON(b, guest)
	}
	b.WriteByte(']')
}

func appendGuestJSON(b *strings.Builder, guest proxmoxGuest) {
	b.WriteByte('{')
	first := true
	appendResourceJSONFields(b, &first, guest.proxmoxResource)
	if len(guest.Config) > 0 {
		appendFieldName(b, &first, "config")
		appendStringMapJSON(b, guest.Config)
	}
	if len(guest.Interfaces) > 0 {
		appendFieldName(b, &first, "interfaces")
		appendGuestInterfacesJSON(b, guest.Interfaces)
	}
	if len(guest.Filesystems) > 0 {
		appendFieldName(b, &first, "filesystems")
		appendGuestFilesystemsJSON(b, guest.Filesystems)
	}
	b.WriteByte('}')
}

func appendResourceJSONFields(b *strings.Builder, first *bool, value proxmoxResource) {
	appendStringField(b, first, "id", value.ID)
	appendStringField(b, first, "node", value.Node)
	appendStringField(b, first, "name", value.Name)
	appendStringField(b, first, "type", value.Type)
	appendStringField(b, first, "status", value.Status)
	appendIntField(b, first, "vmid", value.VMID)
	appendFloatField(b, first, "cpu", value.CPU)
	appendFloatField(b, first, "maxcpu", value.MaxCPU)
	appendFloatField(b, first, "mem", value.Mem)
	appendFloatField(b, first, "maxmem", value.MaxMem)
	appendFloatField(b, first, "disk", value.Disk)
	appendFloatField(b, first, "maxdisk", value.MaxDisk)
	appendFloatField(b, first, "uptime", value.Uptime)
}

func appendGuestInterfacesJSON(b *strings.Builder, interfaces []proxmoxGuestNetworkInterface) {
	b.WriteByte('[')
	for i, iface := range interfaces {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "name", iface.Name)
		appendStringField(b, &first, "config_key", iface.ConfigKey)
		appendStringField(b, &first, "model", iface.Model)
		appendStringField(b, &first, "mac_address", iface.MACAddress)
		if len(iface.IPAddresses) > 0 {
			appendFieldName(b, &first, "ip_addresses")
			appendStringSliceJSON(b, iface.IPAddresses)
		}
		appendStringField(b, &first, "bridge", iface.Bridge)
		appendIntField(b, &first, "vlan_id", iface.VLANID)
		appendStringField(b, &first, "source", iface.Source)
		if len(iface.Metadata) > 0 {
			appendFieldName(b, &first, "metadata")
			appendStringMapJSON(b, iface.Metadata)
		}
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendGuestFilesystemsJSON(b *strings.Builder, filesystems []proxmoxGuestFilesystem) {
	b.WriteByte('[')
	for i, filesystem := range filesystems {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		first := true
		appendStringField(b, &first, "name", filesystem.Name)
		appendStringField(b, &first, "mountpoint", filesystem.Mountpoint)
		appendStringField(b, &first, "type", filesystem.Type)
		appendFloatField(b, &first, "total-bytes", filesystem.TotalBytes)
		appendFloatField(b, &first, "used-bytes", filesystem.UsedBytes)
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func appendCheckSummaryJSON(b *strings.Builder, summary checkSummary) {
	b.WriteString(`{"targets":`)
	b.WriteString(strconv.Itoa(summary.Targets))
	b.WriteString(`,"nodes":`)
	b.WriteString(strconv.Itoa(summary.Nodes))
	b.WriteString(`,"guests":`)
	b.WriteString(strconv.Itoa(summary.Guests))
	b.WriteString(`,"qemu":`)
	b.WriteString(strconv.Itoa(summary.QEMU))
	b.WriteString(`,"lxc":`)
	b.WriteString(strconv.Itoa(summary.LXC))
	b.WriteString(`,"storage":`)
	b.WriteString(strconv.Itoa(summary.Storage))
	b.WriteString(`,"network_interfaces":`)
	b.WriteString(strconv.Itoa(summary.NetworkInterfaces))
	b.WriteString(`,"disks":`)
	b.WriteString(strconv.Itoa(summary.Disks))
	b.WriteString(`,"ceph_enabled_nodes":`)
	b.WriteString(strconv.Itoa(summary.CephEnabledNodes))
	b.WriteString(`,"bottleneck_events":`)
	b.WriteString(strconv.Itoa(summary.Bottleneck))
	b.WriteByte('}')
}

func appendResourceSummaryJSON(b *strings.Builder, summary resourceSummary) {
	b.WriteByte('{')
	first := true
	appendFloatField(b, &first, "max_node_cpu_ratio", summary.MaxNodeCPURatio)
	appendFloatField(b, &first, "max_node_mem_ratio", summary.MaxNodeMemRatio)
	appendFloatField(b, &first, "max_node_io_wait_ratio", summary.MaxNodeIOWaitRatio)
	appendFloatField(b, &first, "max_node_storage_ratio", summary.MaxNodeStorageRatio)
	appendFloatField(b, &first, "max_guest_cpu_ratio", summary.MaxGuestCPURatio)
	appendFloatField(b, &first, "max_guest_mem_ratio", summary.MaxGuestMemRatio)
	appendFloatField(b, &first, "max_guest_disk_ratio", summary.MaxGuestDiskRatio)
	appendIntField(b, &first, "running_guests", summary.RunningGuests)
	appendIntField(b, &first, "stopped_guests", summary.StoppedGuests)
	appendIntField(b, &first, "online_nodes", summary.OnlineNodes)
	appendIntField(b, &first, "offline_nodes", summary.OfflineNodes)
	appendIntField(b, &first, "storage_count", summary.StorageCount)
	appendIntField(b, &first, "network_interface_count", summary.NetworkInterfaceCount)
	appendIntField(b, &first, "disk_count", summary.DiskCount)
	appendIntField(b, &first, "ceph_enabled_nodes", summary.CephEnabledNodes)
	appendIntField(b, &first, "ceph_warn_nodes", summary.CephWarnNodes)
	appendIntField(b, &first, "ceph_error_nodes", summary.CephErrorNodes)
	appendIntField(b, &first, "resource_bottleneck_events", summary.ResourceBottleneck)
	b.WriteByte('}')
}

func appendStringMapJSON(b *strings.Builder, values map[string]string) {
	b.WriteByte('{')
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sortStrings(keys)
	for i, key := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Quote(key))
		b.WriteByte(':')
		b.WriteString(strconv.Quote(values[key]))
	}
	b.WriteByte('}')
}

func appendStringSliceJSON(b *strings.Builder, values []string) {
	b.WriteByte('[')
	for i, value := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Quote(value))
	}
	b.WriteByte(']')
}

func appendAnyMapJSON(b *strings.Builder, values map[string]any) {
	b.WriteByte('{')
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sortStrings(keys)
	for i, key := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Quote(key))
		b.WriteByte(':')
		appendAnyJSON(b, values[key])
	}
	b.WriteByte('}')
}

func appendAnyJSON(b *strings.Builder, value any) {
	switch typed := value.(type) {
	case nil:
		b.WriteString("null")
	case string:
		b.WriteString(strconv.Quote(typed))
	case bool:
		b.WriteString(strconv.FormatBool(typed))
	case int:
		b.WriteString(strconv.Itoa(typed))
	case int64:
		b.WriteString(strconv.FormatInt(typed, 10))
	case uint64:
		b.WriteString(strconv.FormatUint(typed, 10))
	case float64:
		b.WriteString(strconv.FormatFloat(typed, 'f', -1, 64))
	case map[string]any:
		appendAnyMapJSON(b, typed)
	case map[string]string:
		appendStringMapJSON(b, typed)
	case []string:
		appendStringSliceJSON(b, typed)
	case time.Time:
		b.WriteString(strconv.Quote(typed.UTC().Format(time.RFC3339Nano)))
	case fmt.Stringer:
		b.WriteString(strconv.Quote(typed.String()))
	default:
		b.WriteString(strconv.Quote(fmt.Sprint(typed)))
	}
}

func appendStringField(b *strings.Builder, first *bool, name, value string) {
	if value == "" {
		return
	}
	appendFieldName(b, first, name)
	b.WriteString(strconv.Quote(value))
}

func appendIntField(b *strings.Builder, first *bool, name string, value int) {
	if value == 0 {
		return
	}
	appendFieldName(b, first, name)
	b.WriteString(strconv.Itoa(value))
}

func appendFloatField(b *strings.Builder, first *bool, name string, value float64) {
	if value == 0 {
		return
	}
	appendFieldName(b, first, name)
	b.WriteString(strconv.FormatFloat(value, 'f', -1, 64))
}

func appendFieldName(b *strings.Builder, first *bool, name string) {
	appendComma(b, first)
	b.WriteString(strconv.Quote(name))
	b.WriteByte(':')
}

func appendComma(b *strings.Builder, first *bool) {
	if *first {
		*first = false
		return
	}
	b.WriteByte(',')
}

func emptyResourceSummary(summary resourceSummary) bool {
	return summary == resourceSummary{}
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}

func truncateString(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if len(value) <= limit {
		return value
	}

	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}

	return string(runes[:limit]) + "..."
}
