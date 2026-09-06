package main

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"
)

func fetchVersion(cfg Config, target Target, token string) (proxmoxVersion, error) {
	var envelope proxmoxVersionResponse
	if err := getJSON(cfg, target, token, "/api2/json/version", &envelope); err != nil {
		return proxmoxVersion{}, fmt.Errorf("fetch version: %w", err)
	}

	return envelope.Data, nil
}

func fetchClusterStatus(cfg Config, target Target, token string) ([]proxmoxClusterNode, error) {
	var envelope proxmoxClusterStatusResponse
	if err := getJSON(cfg, target, token, "/api2/json/cluster/status", &envelope); err != nil {
		return nil, fmt.Errorf("fetch cluster status: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodes(cfg Config, target Target, token string) ([]proxmoxNode, error) {
	var envelope proxmoxNodesResponse
	if err := getJSON(cfg, target, token, "/api2/json/nodes", &envelope); err != nil {
		return nil, fmt.Errorf("fetch nodes: %w", err)
	}

	return envelope.Data, nil
}

func fetchGuests(
	cfg Config,
	target Target,
	token string,
	nodes []proxmoxNode,
	warnings map[string]string,
) []proxmoxResource {
	guests := make([]proxmoxResource, 0)
	limitReached := false

	for _, node := range nodes {
		nodeName := strings.TrimSpace(node.Node)
		if nodeName == "" {
			continue
		}

		for _, kind := range []string{"qemu", "lxc"} {
			resources, err := fetchNodeGuests(cfg, target, token, nodeName, kind)
			if err != nil {
				warnings[fmt.Sprintf("node:%s:%s_guests", nodeName, kind)] = sanitizeError(err)
				continue
			}

			guests, limitReached = appendGuestResourcesWithinLimit(guests, resources, cfg.MaxGuests)
			if limitReached {
				warnings["guests:limit"] = fmt.Sprintf("guest listing truncated at max_guests=%d", cfg.MaxGuests)
				return guests
			}
		}
	}

	return guests
}

func fetchNodeGuests(cfg Config, target Target, token, node, kind string) ([]proxmoxResource, error) {
	var envelope proxmoxResourcesResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/%s", url.PathEscape(node), kind)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node %s guests: %w", kind, err)
	}

	return normalizeNodeGuestResources(envelope.Data, node, kind), nil
}

func normalizeNodeGuestResources(resources []proxmoxResource, node, kind string) []proxmoxResource {
	out := make([]proxmoxResource, 0, len(resources))
	for _, resource := range resources {
		if resource.Node == "" {
			resource.Node = node
		}
		if resource.Type == "" {
			resource.Type = kind
		}
		if resource.ID == "" && resource.VMID > 0 {
			resource.ID = fmt.Sprintf("%s/%d", kind, resource.VMID)
		}
		out = append(out, resource)
	}

	return out
}

func appendGuestResourcesWithinLimit(
	current []proxmoxResource,
	incoming []proxmoxResource,
	limit int,
) ([]proxmoxResource, bool) {
	if limit <= 0 {
		return append(current, incoming...), false
	}
	remaining := limit - len(current)
	if remaining <= 0 {
		return current, len(incoming) > 0
	}
	if len(incoming) > remaining {
		return append(current, incoming[:remaining]...), true
	}

	return append(current, incoming...), false
}

func enrichNodes(cfg Config, target Target, token string, nodes []proxmoxNode, warnings map[string]string) []proxmoxNode {
	out := make([]proxmoxNode, 0, len(nodes))
	for _, node := range nodes {
		status, err := fetchNodeStatus(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":status"] = sanitizeError(err)
		} else {
			node.RuntimeState = status
		}

		storage, err := fetchNodeStorage(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":storage"] = sanitizeError(err)
		} else {
			node.Storage = storage
		}

		network, err := fetchNodeNetwork(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":network"] = sanitizeError(err)
		} else {
			node.Network = network
		}

		disks, err := fetchNodeDisks(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":disks"] = sanitizeError(err)
		} else {
			node.Disks = disks
		}

		ceph, err := fetchNodeCeph(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":ceph"] = sanitizeError(err)
		} else if !ceph.empty() {
			node.Ceph = &ceph
		}
		out = append(out, node)
	}

	return out
}

func annotateNodesWithClusterStatus(nodes []proxmoxNode, cluster []proxmoxClusterNode) []proxmoxNode {
	if len(nodes) == 0 {
		return nodes
	}

	clusterByNode := make(map[string]proxmoxClusterNode, len(cluster))
	for _, entry := range cluster {
		if !strings.EqualFold(strings.TrimSpace(entry.Type), "node") {
			continue
		}
		name := firstNonEmpty(entry.Name, strings.TrimPrefix(entry.ID, "node/"))
		if name == "" {
			continue
		}
		clusterByNode[strings.ToLower(name)] = entry
	}

	out := make([]proxmoxNode, 0, len(nodes))
	for _, node := range nodes {
		if entry, ok := clusterByNode[strings.ToLower(strings.TrimSpace(node.Node))]; ok {
			if node.IP == "" {
				node.IP = strings.TrimSpace(entry.IP)
			}
		}
		if node.IP == "" {
			node.IP = primaryNodeIP(node.Network)
		}
		out = append(out, node)
	}

	return out
}

func primaryNodeIP(interfaces []proxmoxNetworkInterface) string {
	for _, iface := range interfaces {
		if ip := normalizedNodeIP(iface.Address); ip != "" {
			return ip
		}
		if ip := normalizedNodeIP(iface.CIDR); ip != "" {
			return ip
		}
	}

	return ""
}

func normalizedNodeIP(value string) string {
	value = stripIPPrefix(value)
	if value == "" {
		return ""
	}

	lower := strings.ToLower(value)
	if lower == "127.0.0.1" || lower == "::1" || strings.HasPrefix(lower, "169.254.") || strings.HasPrefix(lower, "fe80:") {
		return ""
	}

	return value
}

func fetchNodeStatus(cfg Config, target Target, token, node string) (proxmoxNodeStatus, error) {
	var envelope proxmoxNodeStatusResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return proxmoxNodeStatus{}, fmt.Errorf("fetch node status: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeStorage(cfg Config, target Target, token, node string) ([]proxmoxStorage, error) {
	var envelope proxmoxStorageResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/storage"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node storage: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeNetwork(cfg Config, target Target, token, node string) ([]proxmoxNetworkInterface, error) {
	var envelope proxmoxNetworkResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/network"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node network: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeDisks(cfg Config, target Target, token, node string) ([]proxmoxDisk, error) {
	var envelope proxmoxDiskResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/disks/list"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node disks: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeCeph(cfg Config, target Target, token, node string) (proxmoxCeph, error) {
	status, err := fetchNodeCephStatus(cfg, target, token, node)
	if err != nil {
		return proxmoxCeph{}, err
	}

	ceph := proxmoxCeph{
		Health: cephHealth(status),
	}

	return ceph, nil
}

func fetchNodeCephStatus(cfg Config, target Target, token, node string) (proxmoxCephStatus, error) {
	var envelope proxmoxCephStatusResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/ceph/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return proxmoxCephStatus{}, fmt.Errorf("fetch node ceph status: %w", err)
	}

	return envelope.Data, nil
}

func enrichGuests(cfg Config, target Target, token string, guests []proxmoxResource, deadline time.Time, warnings map[string]string) []proxmoxGuest {
	out := make([]proxmoxGuest, 0, len(guests))
	for i, resource := range guests {
		// Per-node time budget: once exhausted, emit the remaining guests as
		// bare devices (still discovered, just without runtime interface/disk
		// detail) instead of letting one slow node run out the poll window.
		if !deadline.IsZero() && time.Now().After(deadline) {
			for _, remaining := range guests[i:] {
				out = append(out, proxmoxGuest{proxmoxResource: remaining})
			}
			warnings[fmt.Sprintf("node:%s:enrich_budget", resource.Node)] =
				fmt.Sprintf("per-node enrichment budget exhausted; %d guest(s) emitted without runtime detail", len(guests)-i)
			break
		}

		guest := proxmoxGuest{proxmoxResource: resource}
		kind := guestEndpointKind(resource.Type)
		if kind == "" || resource.Node == "" || resource.VMID <= 0 {
			out = append(out, guest)
			continue
		}

		agentEnabled := false
		config, err := fetchGuestConfig(cfg, target, token, resource.Node, kind, resource.VMID)
		if err != nil {
			warnings[fmt.Sprintf("guest:%s:%d:config", kind, resource.VMID)] = sanitizeError(err)
		} else {
			// Parse interfaces from the full (sanitized) config, but retain only a
			// small metadata allowlist on the guest. Keeping the entire raw config
			// (every disk line, cloud-init user-data, smbios, …) for every guest
			// blew the WASM heap and the 2MB submit_result cap on large clusters.
			sanitized := sanitizeStringMap(config)
			guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromGuestConfig(sanitized))
			guest.Config = trimGuestConfig(sanitized)
			agentEnabled = guestAgentEnabled(sanitized)
		}

		// Runtime probes (qemu-guest-agent, lxc interfaces) are the expensive
		// calls: a stopped or unresponsive agent blocks each request until the
		// per-request timeout, and doing that for every guest is what blew the
		// plugin execution deadline on large clusters. Skip them entirely when
		// the config already yielded a usable IP (static netN, or cloud-init
		// ipconfigN) — that address is enough to place the guest as a device.
		// Only probe the qemu-guest-agent when it is actually enabled.
		hasConfigIP := primaryIP(guest.Interfaces) != ""

		// Best-effort runtime probes get a short deadline. An installed-but-
		// unresponsive guest agent otherwise blocks each call for the full
		// request timeout, and a handful of those per node pushed enumeration
		// past the config-delivery window (so later nodes never got scanned).
		// The address/disk these probes recover is a bonus — config IPs are
		// already handled above — so failing fast is the right trade.
		probeCfg := cfg
		if probeCfg.TimeoutMS <= 0 || probeCfg.TimeoutMS > guestProbeTimeoutMS {
			probeCfg.TimeoutMS = guestProbeTimeoutMS
		}

		if kind == "qemu" && agentEnabled && !hasConfigIP && strings.EqualFold(resource.Status, "running") {
			agentInterfaces, err := fetchGuestAgentNetworkInterfaces(probeCfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:agent_network", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromGuestAgent(agentInterfaces))
			}

			filesystems, err := fetchGuestAgentFilesystems(probeCfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:agent_filesystems", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Filesystems = filterGuestFilesystems(filesystems)
				if used, total := summarizeGuestFilesystems(guest.Filesystems); total > 0 {
					guest.Disk = used
					guest.MaxDisk = total
				}
			}
		}

		if kind == "lxc" && !hasConfigIP && strings.EqualFold(resource.Status, "running") {
			lxcInterfaces, err := fetchLXCInterfaces(probeCfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:interfaces", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromLXCInterfaces(lxcInterfaces))
			}
		}

		out = append(out, guest)
	}

	return out
}

func fetchGuestConfig(cfg Config, target Target, token, node, kind string, vmid int) (map[string]string, error) {
	var envelope proxmoxStringMapResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/%s/%d/config", url.PathEscape(node), kind, vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest config: %w", err)
	}

	return envelope.Data, nil
}

func fetchGuestAgentNetworkInterfaces(cfg Config, target Target, token, node string, vmid int) ([]proxmoxGuestAgentInterface, error) {
	var envelope proxmoxGuestAgentNetworkResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/qemu/%d/agent/network-get-interfaces", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest agent network interfaces: %w", err)
	}

	return envelope.Data.Result, nil
}

func fetchGuestAgentFilesystems(cfg Config, target Target, token, node string, vmid int) ([]proxmoxGuestFilesystem, error) {
	var envelope proxmoxGuestAgentFSInfoResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/qemu/%d/agent/get-fsinfo", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest agent filesystems: %w", err)
	}

	return envelope.Data.Result, nil
}

func fetchLXCInterfaces(cfg Config, target Target, token, node string, vmid int) ([]proxmoxLXCInterface, error) {
	var envelope proxmoxLXCInterfacesResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/lxc/%d/interfaces", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch lxc interfaces: %w", err)
	}

	return envelope.Data, nil
}

func interfacesFromGuestConfig(config map[string]string) []proxmoxGuestNetworkInterface {
	if len(config) == 0 {
		return nil
	}

	netKeys := make([]string, 0)
	ipConfigKeys := make([]string, 0)
	for key := range config {
		switch {
		case isGuestNetConfigKey(key):
			netKeys = append(netKeys, key)
		case isGuestIPConfigKey(key):
			ipConfigKeys = append(ipConfigKeys, key)
		}
	}
	sort.Strings(netKeys)
	sort.Strings(ipConfigKeys)

	// Build the netN interfaces first, tracking each by its numeric index so a
	// matching ipconfigN can merge its address on. Interfaces are NOT dropped
	// here for lacking an IP — a QEMU netN typically only carries a MAC, and its
	// cloud-init IP lives in ipconfigN (merged below); the final filter runs
	// after that merge.
	out := make([]proxmoxGuestNetworkInterface, 0, len(netKeys))
	byIndex := make(map[string]int, len(netKeys))
	for _, key := range netKeys {
		raw := config[key]
		if strings.TrimSpace(raw) == "" {
			continue
		}
		byIndex[configKeyIndex(key, "net")] = len(out)
		out = append(out, interfaceFromGuestConfigValue(key, raw))
	}

	// Cloud-init QEMU guests carry their IP in ipconfigN (e.g.
	// `ipconfig0: ip=10.0.0.5/24,gw=…`), never in netN, so netN parsing alone
	// leaves them IP-less. Merge ipconfigN addresses onto the matching netN
	// interface by index (ipconfig0 <-> net0).
	for _, key := range ipConfigKeys {
		values := parseProxmoxConfigList(config[key])
		var ips []string
		for _, k := range []string{"ip", "ip6"} {
			if ip := normalizeGuestIP(values[k]); ip != "" {
				ips = appendUniqueString(ips, ip)
			}
		}
		if len(ips) == 0 {
			continue
		}

		idx := configKeyIndex(key, "ipconfig")
		if pos, ok := byIndex[idx]; ok {
			for _, ip := range ips {
				out[pos].IPAddresses = appendUniqueString(out[pos].IPAddresses, ip)
			}
		} else {
			byIndex[idx] = len(out)
			out = append(out, proxmoxGuestNetworkInterface{
				ConfigKey:   "net" + idx,
				Name:        "net" + idx,
				Source:      "cloudinit",
				IPAddresses: ips,
			})
		}
	}

	filtered := out[:0]
	for _, iface := range out {
		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		filtered = append(filtered, iface)
	}

	return filtered
}

// configKeyIndex returns the numeric suffix of a proxmox config key
// (e.g. configKeyIndex("net0","net") == "0", configKeyIndex("ipconfig12","ipconfig") == "12").
func configKeyIndex(key, prefix string) string {
	return strings.TrimPrefix(key, prefix)
}

func isGuestIPConfigKey(key string) bool {
	if !strings.HasPrefix(key, "ipconfig") || len(key) == len("ipconfig") {
		return false
	}
	for _, r := range key[len("ipconfig"):] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// trimGuestConfig keeps only a small, cheap metadata allowlist from a guest's
// raw Proxmox config. The interesting network data has already been extracted
// into structured interfaces; retaining the entire config map per guest (disks,
// cloud-init user-data, smbios, …) is what exhausted the WASM heap and the 2MB
// result cap on large clusters.
func trimGuestConfig(config map[string]string) map[string]string {
	if len(config) == 0 {
		return nil
	}

	allow := []string{
		"name", "ostype", "arch", "cores", "sockets", "cpu",
		"memory", "onboot", "tags", "description", "template", "hostname",
	}

	out := make(map[string]string, len(allow))
	for _, key := range allow {
		if value, ok := config[key]; ok && strings.TrimSpace(value) != "" {
			out[key] = value
		}
	}

	if len(out) == 0 {
		return nil
	}

	return out
}

// guestAgentEnabled reports whether a QEMU guest has the qemu-guest-agent
// enabled in its config (`agent: 1` / `agent: enabled=1,…`). When false, the
// agent network/fsinfo probes are skipped to avoid blocking on a guest that
// will never answer.
func guestAgentEnabled(config map[string]string) bool {
	raw := strings.TrimSpace(config["agent"])
	if raw == "" {
		return false
	}

	if first := strings.TrimSpace(strings.SplitN(raw, ",", 2)[0]); first == "1" {
		return true
	}

	return strings.TrimSpace(parseProxmoxConfigList(raw)["enabled"]) == "1"
}

func isGuestNetConfigKey(key string) bool {
	if !strings.HasPrefix(key, "net") || len(key) == 3 {
		return false
	}
	for _, r := range key[3:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func interfaceFromGuestConfigValue(configKey, raw string) proxmoxGuestNetworkInterface {
	values := parseProxmoxConfigList(raw)
	iface := proxmoxGuestNetworkInterface{
		ConfigKey: configKey,
		Name:      firstNonEmpty(values["name"], configKey),
		Bridge:    values["bridge"],
		Source:    "config",
	}

	if vlanID := parsePositiveInt(firstNonEmpty(values["tag"], values["vlan-id"], values["vlan_id"])); vlanID > 0 {
		iface.VLANID = vlanID
	}

	for _, key := range []string{"hwaddr", "macaddr", "mac"} {
		if mac := normalizeMACForOutput(values[key]); mac != "" {
			iface.MACAddress = mac
			break
		}
	}

	if iface.MACAddress == "" {
		for _, model := range []string{"virtio", "e1000", "e1000e", "rtl8139", "vmxnet3", "ne2k_pci", "i82551", "i82557b", "i82559er"} {
			if mac := normalizeMACForOutput(values[model]); mac != "" {
				iface.MACAddress = mac
				iface.Model = model
				break
			}
		}
	}

	if iface.Model == "" {
		iface.Model = firstNonEmpty(values["type"], values["model"])
	}

	for _, key := range []string{"ip", "ip6"} {
		if ip := normalizeGuestIP(values[key]); ip != "" {
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}
	}

	return iface
}

func parseProxmoxConfigList(raw string) map[string]string {
	values := map[string]string{}
	for _, part := range strings.Split(raw, ",") {
		key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		if key != "" && value != "" {
			values[key] = value
		}
	}
	return values
}

func interfacesFromGuestAgent(agentInterfaces []proxmoxGuestAgentInterface) []proxmoxGuestNetworkInterface {
	out := make([]proxmoxGuestNetworkInterface, 0, len(agentInterfaces))
	for _, agentIface := range agentInterfaces {
		iface := proxmoxGuestNetworkInterface{
			Name:       agentIface.Name,
			MACAddress: normalizeMACForOutput(agentIface.HardwareAddress),
			Source:     "guest_agent",
		}

		for _, address := range agentIface.IPAddresses {
			ip := normalizeGuestIP(address.IPAddress)
			if ip == "" || isLoopbackOrLinkLocal(ip) {
				continue
			}
			if address.Prefix > 0 && !strings.Contains(ip, "/") {
				ip = fmt.Sprintf("%s/%d", ip, address.Prefix)
			}
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}

		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		out = append(out, iface)
	}

	return out
}

func interfacesFromLXCInterfaces(lxcInterfaces []proxmoxLXCInterface) []proxmoxGuestNetworkInterface {
	out := make([]proxmoxGuestNetworkInterface, 0, len(lxcInterfaces))
	for _, lxcIface := range lxcInterfaces {
		iface := proxmoxGuestNetworkInterface{
			Name:       lxcIface.Name,
			MACAddress: normalizeMACForOutput(firstNonEmpty(lxcIface.MACAddress, lxcIface.Hardware)),
			Source:     "lxc_interfaces",
		}

		for _, ip := range []string{lxcIface.Inet, lxcIface.Inet6} {
			ip = normalizeGuestIP(ip)
			if ip == "" || isLoopbackOrLinkLocal(ip) {
				continue
			}
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}

		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		out = append(out, iface)
	}

	return out
}

func filterGuestFilesystems(filesystems []proxmoxGuestFilesystem) []proxmoxGuestFilesystem {
	out := make([]proxmoxGuestFilesystem, 0, len(filesystems))
	for _, fs := range filesystems {
		if fs.TotalBytes <= 0 || ignoredGuestFilesystem(fs) {
			continue
		}
		out = append(out, fs)
	}
	return out
}

func summarizeGuestFilesystems(filesystems []proxmoxGuestFilesystem) (float64, float64) {
	var used, total float64
	for _, fs := range filesystems {
		if fs.TotalBytes <= 0 {
			continue
		}
		used += fs.UsedBytes
		total += fs.TotalBytes
	}
	return used, total
}

func ignoredGuestFilesystem(fs proxmoxGuestFilesystem) bool {
	fsType := strings.ToLower(strings.TrimSpace(fs.Type))
	switch fsType {
	case "tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2", "overlay", "squashfs",
		"tracefs", "debugfs", "securityfs", "pstore", "bpf", "fusectl", "mqueue", "hugetlbfs",
		"rpc_pipefs", "nsfs", "autofs":
		return true
	}

	mountpoint := strings.TrimSpace(fs.Mountpoint)
	return strings.HasPrefix(mountpoint, "/proc") ||
		strings.HasPrefix(mountpoint, "/sys") ||
		strings.HasPrefix(mountpoint, "/dev") ||
		strings.HasPrefix(mountpoint, "/run")
}

func mergeGuestInterfaces(left, right []proxmoxGuestNetworkInterface) []proxmoxGuestNetworkInterface {
	out := append([]proxmoxGuestNetworkInterface{}, left...)
	for _, incoming := range right {
		idx := findGuestInterface(out, incoming)
		if idx < 0 {
			out = append(out, incoming)
			continue
		}

		current := out[idx]
		current.Name = firstNonEmpty(current.Name, incoming.Name)
		current.ConfigKey = firstNonEmpty(current.ConfigKey, incoming.ConfigKey)
		current.Model = firstNonEmpty(current.Model, incoming.Model)
		current.MACAddress = firstNonEmpty(current.MACAddress, incoming.MACAddress)
		current.Bridge = firstNonEmpty(current.Bridge, incoming.Bridge)
		if current.VLANID == 0 {
			current.VLANID = incoming.VLANID
		}
		current.Source = mergeSource(current.Source, incoming.Source)
		current.IPAddresses = appendUniqueStrings(current.IPAddresses, incoming.IPAddresses)
		current.Metadata = mergeMetadata(current.Metadata, incoming.Metadata)
		out[idx] = current
	}

	return out
}

func findGuestInterface(interfaces []proxmoxGuestNetworkInterface, incoming proxmoxGuestNetworkInterface) int {
	incomingMAC := normalizeMACKey(incoming.MACAddress)
	for idx, candidate := range interfaces {
		if incomingMAC != "" && normalizeMACKey(candidate.MACAddress) == incomingMAC {
			return idx
		}
		if incoming.Name != "" && candidate.Name != "" && strings.EqualFold(candidate.Name, incoming.Name) {
			return idx
		}
		if incoming.ConfigKey != "" && candidate.ConfigKey != "" && candidate.ConfigKey == incoming.ConfigKey {
			return idx
		}
	}

	return -1
}

func mergeSource(left, right string) string {
	switch {
	case left == "":
		return right
	case right == "", left == right:
		return left
	case strings.Contains(left, right):
		return left
	case strings.Contains(right, left):
		return right
	default:
		return left + "," + right
	}
}

func mergeMetadata(left, right map[string]string) map[string]string {
	if len(left) == 0 {
		return right
	}
	if len(right) == 0 {
		return left
	}
	merged := make(map[string]string, len(left)+len(right))
	for key, value := range left {
		merged[key] = value
	}
	for key, value := range right {
		if _, exists := merged[key]; !exists {
			merged[key] = value
		}
	}
	return merged
}
