package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func (target Target) safeName() string {
	return firstNonEmpty(target.Hostname, target.DeviceID, target.redactedBaseURL())
}

func (target Target) redactedBaseURL() string {
	return strings.TrimSpace(target.BaseURL)
}

func targetMetadata(target Target) map[string]string {
	meta := map[string]string{}
	if target.DeviceID != "" {
		meta["device_id"] = target.DeviceID
	}
	if target.Hostname != "" {
		meta["hostname"] = target.Hostname
	}
	if target.Partition != "" {
		meta["partition"] = target.Partition
	}
	if len(meta) == 0 {
		return nil
	}

	return meta
}

func (target proxmoxTarget) safeEventPrefix() string {
	if target.Meta != nil {
		if deviceID := strings.TrimSpace(target.Meta["device_id"]); deviceID != "" {
			return deviceID + ":"
		}
		if hostname := strings.TrimSpace(target.Meta["hostname"]); hostname != "" {
			return hostname + ":"
		}
	}
	if target.BaseURL != "" {
		return target.BaseURL + ":"
	}

	return ""
}

func proxmoxGuestID(guest proxmoxResource) string {
	if guest.ID != "" {
		return "proxmox:" + strings.ReplaceAll(guest.ID, "/", ":")
	}

	// Node-independent placeholder uid (matches the enrichment path's
	// proxmox_guest_device_uid): the vmid is cluster-stable across live
	// migration, so keying on it — not the current node — keeps the id from
	// rotating when a guest moves between nodes.
	return fmt.Sprintf("proxmox:%s:%d", normalizeGuestKind(guest.Type), guest.VMID)
}

func normalizeGuestKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "qemu":
		return "vm"
	case "lxc":
		return "container"
	default:
		return "guest"
	}
}

func normalizeMACForOutput(value string) string {
	key := normalizeMACKey(value)
	if key == "" {
		return ""
	}

	parts := make([]string, 0, 6)
	for i := 0; i < len(key); i += 2 {
		parts = append(parts, key[i:i+2])
	}

	return strings.Join(parts, ":")
}

func normalizeMACKey(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	replacer := strings.NewReplacer(":", "", "-", "", ".", "")
	value = replacer.Replace(value)
	if len(value) != 12 {
		return ""
	}
	for _, r := range value {
		if !((r >= '0' && r <= '9') || (r >= 'A' && r <= 'F')) {
			return ""
		}
	}
	return value
}

func normalizeGuestIP(value string) string {
	value = strings.TrimSpace(value)
	switch strings.ToLower(value) {
	case "", "dhcp", "auto", "manual", "none":
		return ""
	default:
		return value
	}
}

func primaryIP(interfaces []proxmoxGuestNetworkInterface) string {
	// Prefer the configured VM NICs (net0/net1...). On a Kubernetes node the
	// guest agent also reports cali*/kube-ipvs0/vxlan interfaces carrying
	// ClusterIP VIPs and overlay IPs (no ConfigKey); picking one of those as
	// the device's primary IP is wrong and non-deterministic (it depends on
	// guest-agent interface order). The configured NIC carries the host's real
	// address, and the merge unions the agent-discovered IP onto it.
	if ip := firstUsableIP(interfaces, true); ip != "" {
		return ip
	}

	return firstUsableIP(interfaces, false)
}

func firstUsableIP(interfaces []proxmoxGuestNetworkInterface, configuredOnly bool) string {
	for _, iface := range interfaces {
		if configuredOnly && iface.ConfigKey == "" {
			continue
		}

		for _, ip := range iface.IPAddresses {
			if plain := stripIPPrefix(ip); plain != "" && !isLoopbackOrLinkLocal(plain) {
				return plain
			}
		}
	}

	return ""
}

func primaryMAC(interfaces []proxmoxGuestNetworkInterface) string {
	// Prefer the configured VM NIC MAC — the stable hardware identity used for
	// reconciliation — over a CNI veth MAC (cali*/vxlan, often a random or
	// all-e MAC like ee:ee:ee:ee:ee:ee).
	for _, iface := range interfaces {
		if iface.ConfigKey != "" && iface.MACAddress != "" {
			return iface.MACAddress
		}
	}

	for _, iface := range interfaces {
		if iface.MACAddress != "" {
			return iface.MACAddress
		}
	}

	return ""
}

func stripIPPrefix(value string) string {
	value = strings.TrimSpace(value)
	if idx := strings.Index(value, "/"); idx >= 0 {
		value = value[:idx]
	}
	return value
}

func isLoopbackOrLinkLocal(value string) bool {
	value = strings.ToLower(stripIPPrefix(value))
	return strings.HasPrefix(value, "127.") ||
		value == "::1" ||
		strings.HasPrefix(value, "169.254.") ||
		strings.HasPrefix(value, "fe80:")
}

func appendUniqueStrings(left []string, right []string) []string {
	for _, value := range right {
		left = appendUniqueString(left, value)
	}
	return left
}

func appendUniqueString(values []string, value string) []string {
	value = strings.TrimSpace(value)
	if value == "" {
		return values
	}
	for _, existing := range values {
		if strings.EqualFold(existing, value) {
			return values
		}
	}
	return append(values, value)
}

func parsePositiveInt(value string) int {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || parsed < 0 {
		return 0
	}
	return parsed
}

func guestEndpointKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "qemu":
		return "qemu"
	case "lxc":
		return "lxc"
	default:
		return ""
	}
}

func summarizeInventory(nodes []proxmoxNode, guests []proxmoxGuest) resourceSummary {
	summary := resourceSummary{}
	for _, node := range nodes {
		if strings.EqualFold(node.Status, "online") {
			summary.OnlineNodes++
		} else {
			summary.OfflineNodes++
		}

		summary.MaxNodeCPURatio = maxFloat(summary.MaxNodeCPURatio, ratio(node.CPU, 1))
		summary.MaxNodeMemRatio = maxFloat(summary.MaxNodeMemRatio, ratio(node.Mem, node.MaxMem))
		summary.MaxNodeIOWaitRatio = maxFloat(summary.MaxNodeIOWaitRatio, ratio(floatValue(node.RuntimeState, "wait"), 1))
		summary.StorageCount += len(node.Storage)
		summary.NetworkInterfaceCount += len(node.Network)
		summary.DiskCount += len(node.Disks)
		for _, storage := range node.Storage {
			summary.MaxNodeStorageRatio = maxFloat(summary.MaxNodeStorageRatio, ratio(storage.Used, storage.Total))
		}
		if node.Ceph != nil {
			summary.CephEnabledNodes++
			switch cephHealthClass(node.Ceph.Health) {
			case "critical":
				summary.CephErrorNodes++
			case "warning":
				summary.CephWarnNodes++
			}
		}
	}

	for _, guest := range guests {
		if strings.EqualFold(guest.Status, "running") {
			summary.RunningGuests++
		} else {
			summary.StoppedGuests++
		}

		summary.MaxGuestCPURatio = maxFloat(summary.MaxGuestCPURatio, ratio(guest.CPU, 1))
		summary.MaxGuestMemRatio = maxFloat(summary.MaxGuestMemRatio, ratio(guest.Mem, guest.MaxMem))
		summary.MaxGuestDiskRatio = maxFloat(summary.MaxGuestDiskRatio, ratio(guest.Disk, guest.MaxDisk))
	}

	summary.ResourceBottleneck = countResourceBottlenecks(nodes, guests)

	return summary
}

func countResourceBottlenecks(nodes []proxmoxNode, guests []proxmoxGuest) int {
	count := 0
	for _, node := range nodes {
		if ratio(node.CPU, 1) >= 0.80 ||
			ratio(node.Mem, node.MaxMem) >= 0.80 ||
			ratio(floatValue(node.RuntimeState, "wait"), 1) >= 0.20 {
			count++
		}
		for _, storage := range node.Storage {
			if ratio(storage.Used, storage.Total) >= 0.80 {
				count++
			}
		}
		if node.Ceph != nil && cephHealthClass(node.Ceph.Health) != "" {
			count++
		}
	}
	for _, guest := range guests {
		if ratio(guest.CPU, 1) >= 0.80 ||
			ratio(guest.Mem, guest.MaxMem) >= 0.80 ||
			ratio(guest.Disk, guest.MaxDisk) >= 0.80 {
			count++
		}
	}

	return count
}

func mergeResourceSummary(acc, next resourceSummary) resourceSummary {
	acc.MaxNodeCPURatio = maxFloat(acc.MaxNodeCPURatio, next.MaxNodeCPURatio)
	acc.MaxNodeMemRatio = maxFloat(acc.MaxNodeMemRatio, next.MaxNodeMemRatio)
	acc.MaxNodeIOWaitRatio = maxFloat(acc.MaxNodeIOWaitRatio, next.MaxNodeIOWaitRatio)
	acc.MaxNodeStorageRatio = maxFloat(acc.MaxNodeStorageRatio, next.MaxNodeStorageRatio)
	acc.MaxGuestCPURatio = maxFloat(acc.MaxGuestCPURatio, next.MaxGuestCPURatio)
	acc.MaxGuestMemRatio = maxFloat(acc.MaxGuestMemRatio, next.MaxGuestMemRatio)
	acc.MaxGuestDiskRatio = maxFloat(acc.MaxGuestDiskRatio, next.MaxGuestDiskRatio)
	acc.RunningGuests += next.RunningGuests
	acc.StoppedGuests += next.StoppedGuests
	acc.OnlineNodes += next.OnlineNodes
	acc.OfflineNodes += next.OfflineNodes
	acc.StorageCount += next.StorageCount
	acc.NetworkInterfaceCount += next.NetworkInterfaceCount
	acc.DiskCount += next.DiskCount
	acc.CephEnabledNodes += next.CephEnabledNodes
	acc.CephWarnNodes += next.CephWarnNodes
	acc.CephErrorNodes += next.CephErrorNodes
	acc.ResourceBottleneck += next.ResourceBottleneck

	return acc
}

func emitResourceEvents(result *pluginResult, details proxmoxDetails) {
	for _, target := range details.Targets {
		for _, node := range target.Nodes {
			emitRatioEvent(result, "node_cpu", target.safeEventPrefix()+node.Node, ratio(node.CPU, 1))
			emitRatioEvent(result, "node_memory", target.safeEventPrefix()+node.Node, ratio(node.Mem, node.MaxMem))
			emitIOWaitEvent(result, target.safeEventPrefix()+node.Node, ratio(floatValue(node.RuntimeState, "wait"), 1))
			for _, storage := range node.Storage {
				emitRatioEvent(result, "node_storage", target.safeEventPrefix()+node.Node+":"+storage.Storage, ratio(storage.Used, storage.Total))
			}
			emitCephHealthEvent(result, target.safeEventPrefix()+node.Node, node.Ceph)
			for _, disk := range node.Disks {
				emitDiskHealthEvent(result, target.safeEventPrefix()+node.Node, disk)
			}
		}
		for _, guest := range target.Guests {
			key := fmt.Sprintf("%s%s:%d", target.safeEventPrefix(), guestEndpointKind(guest.Type), guest.VMID)
			emitRatioEvent(result, "guest_cpu", key, ratio(guest.CPU, 1))
			emitRatioEvent(result, "guest_memory", key, ratio(guest.Mem, guest.MaxMem))
			emitRatioEvent(result, "guest_disk", key, ratio(guest.Disk, guest.MaxDisk))
		}
	}
}

// Pressure bands. A ratio at/above the critical threshold is "critical", at/above
// the warning threshold is "warning", otherwise "ok". These mirror the bands the
// summary/telemetry already use so events and metrics agree.
const (
	ratioWarnThreshold  = 0.80
	ratioCritThreshold  = 0.90
	ioWaitWarnThreshold = 0.20
	ioWaitCritThreshold = 0.40
)

// pressureLevel is the discrete band a resource ratio occupies. Downstream
// de-duplication keys on (condition_key, level), so classifying — rather than
// re-reporting the exact percentage every cycle — is what lets the host suppress
// per-tick repeats while still alerting on a level transition.
type pressureLevel int

const (
	levelOK pressureLevel = iota
	levelWarning
	levelCritical
)

func (l pressureLevel) String() string {
	switch l {
	case levelCritical:
		return "critical"
	case levelWarning:
		return "warning"
	default:
		return "ok"
	}
}

// classifyPressureLevel buckets a ratio into ok/warning/critical using the
// warn/crit thresholds. This is a pure threshold classification: hysteresis
// (which needs the PRIOR level) is applied host-side, where cross-cycle state
// lives. A WASM plugin is re-instantiated every check cycle and cannot remember
// a prior level itself, so it reports the current level plus the raw ratio and
// thresholds and lets the long-lived host decide whether the level transitioned.
func classifyPressureLevel(value, warn, crit float64) pressureLevel {
	switch {
	case value >= crit:
		return levelCritical
	case value >= warn:
		return levelWarning
	default:
		return levelOK
	}
}

func emitIOWaitEvent(result *pluginResult, key string, value float64) {
	emitPressureEvent(result, "proxmox:node_io_wait:"+key, "node I/O wait", value, ioWaitWarnThreshold, ioWaitCritThreshold)
}

func emitRatioEvent(result *pluginResult, kind, key string, value float64) {
	emitPressureEvent(result, "proxmox:"+kind+":"+key, strings.ReplaceAll(kind, "_", " "), value, ratioWarnThreshold, ratioCritThreshold)
}

// emitPressureEvent emits a single condition event for the resource's current
// LEVEL rather than one event per percentage tick. The precise ratio and the
// warn/crit thresholds ride along in `unmapped` so the host de-duplicator can
// apply hysteresis at the band boundaries. Nothing is emitted while the resource
// is OK — a recovery is represented by the absence of further events for the
// condition key (the host ages the condition out).
func emitPressureEvent(result *pluginResult, conditionKey, label string, value, warn, crit float64) {
	level := classifyPressureLevel(value, warn, crit)
	extra := map[string]any{"ratio": value, "warn": warn, "crit": crit}

	switch level {
	case levelCritical:
		result.EmitConditionEvent(
			sdk.SeverityCritical,
			fmt.Sprintf("Proxmox %s bottleneck (critical)", label),
			conditionKey,
			level.String(),
			extra,
		)
	case levelWarning:
		result.EmitConditionEvent(
			sdk.SeverityWarning,
			fmt.Sprintf("Proxmox %s pressure (warning)", label),
			conditionKey,
			level.String(),
			extra,
		)
	}
}

func emitCephHealthEvent(result *pluginResult, key string, ceph *proxmoxCeph) {
	if ceph == nil {
		return
	}

	switch cephHealthClass(ceph.Health) {
	case "critical":
		result.EmitConditionEvent(
			sdk.SeverityCritical,
			"Proxmox Ceph health critical: "+ceph.Health,
			"proxmox:ceph_health:"+key,
			levelCritical.String(),
			nil,
		)
	case "warning":
		result.EmitConditionEvent(
			sdk.SeverityWarning,
			"Proxmox Ceph health warning: "+ceph.Health,
			"proxmox:ceph_health:"+key,
			levelWarning.String(),
			nil,
		)
	}
}

func emitDiskHealthEvent(result *pluginResult, key string, disk proxmoxDisk) {
	health := strings.ToUpper(strings.TrimSpace(disk.Health))
	if health == "" || health == "OK" || health == "PASSED" {
		return
	}

	diskID := firstNonEmpty(disk.DevPath, disk.ByID, disk.Model, "disk")
	result.EmitConditionEvent(
		sdk.SeverityWarning,
		"Proxmox disk health warning: "+diskID+" "+health,
		"proxmox:disk_health:"+key+":"+diskID,
		levelWarning.String(),
		nil,
	)
}

func countGuests(guests []proxmoxGuest, guestType string) int {
	count := 0
	for _, guest := range guests {
		if strings.EqualFold(guest.Type, guestType) {
			count++
		}
	}

	return count
}

func (ceph proxmoxCeph) empty() bool {
	return ceph.Health == ""
}

func cephHealth(status proxmoxCephStatus) string {
	return firstNonEmpty(status.Health, status.OverallStatus, status.Status)
}

func cephHealthClass(health string) string {
	health = strings.ToUpper(strings.TrimSpace(health))
	switch {
	case health == "":
		return ""
	case strings.Contains(health, "ERR") || strings.Contains(health, "CRIT"):
		return "critical"
	case strings.Contains(health, "WARN"):
		return "warning"
	default:
		return ""
	}
}

func ratio(value, maxValue float64) float64 {
	if value <= 0 || maxValue <= 0 {
		return 0
	}
	if value > 1 && maxValue == 1 {
		return 1
	}

	return value / maxValue
}

func maxFloat(a, b float64) float64 {
	if b > a {
		return b
	}

	return a
}

func floatValue(values proxmoxNodeStatus, key string) float64 {
	switch key {
	case "wait":
		return values.Wait
	default:
		return 0
	}
}

func stringAny(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return ""
	}
}

func nilIfEmpty(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}

	return values
}

func sanitizeStringMap(raw map[string]string) map[string]string {
	if len(raw) == 0 {
		return nil
	}

	sanitized := make(map[string]string, len(raw))
	for key, value := range raw {
		if sensitiveKey(key) {
			sanitized[key] = "REDACTED"
			continue
		}
		sanitized[key] = sanitizeSecretString(value)
	}

	return sanitized
}

func sanitizeMap(raw map[string]any) map[string]any {
	if len(raw) == 0 {
		return nil
	}

	sanitized := make(map[string]any, len(raw))
	for key, value := range raw {
		if sensitiveKey(key) {
			sanitized[key] = "REDACTED"
			continue
		}
		sanitized[key] = sanitizeAny(value)
	}

	return sanitized
}

func sanitizeAny(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		return sanitizeMap(typed)
	case []any:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, sanitizeAny(item))
		}
		return out
	case string:
		return sanitizeSecretString(typed)
	default:
		return value
	}
}

func sanitizeMapList(raw []map[string]any) []map[string]any {
	if len(raw) == 0 {
		return nil
	}

	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		out = append(out, sanitizeMap(item))
	}

	return out
}

func sensitiveKey(key string) bool {
	normalized := strings.ToLower(strings.TrimSpace(key))
	for _, needle := range []string{"password", "passwd", "secret", "token", "credential", "apikey", "api_key", "privatekey", "private_key"} {
		if strings.Contains(normalized, needle) {
			return true
		}
	}

	return false
}

func sanitizeSecretString(value string) string {
	if strings.Contains(value, "PVEAPIToken=") {
		return redactPVEAPITokenMaterial(value)
	}

	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}

	return ""
}

func joinErrors(errorsByTarget map[string]string) string {
	parts := make([]string, 0, len(errorsByTarget))
	for target, reason := range errorsByTarget {
		parts = append(parts, target+": "+reason)
	}

	return strings.Join(parts, "; ")
}

func sanitizeError(err error) string {
	if err == nil {
		return ""
	}

	msg := err.Error()
	msg = redactPVEAPITokenMaterial(msg)

	return msg
}

func redactPVEAPITokenMaterial(value string) string {
	const marker = "PVEAPIToken="
	searchStart := 0

	for {
		relativeIdx := strings.Index(value[searchStart:], marker)
		if relativeIdx < 0 {
			return value
		}

		idx := searchStart + relativeIdx
		end := idx + len(marker)
		for end < len(value) {
			switch value[end] {
			case '"', '\'', ',', '}', ']', '<', ' ', '\t', '\n', '\r':
				value = value[:idx] + marker + "REDACTED" + value[end:]
				searchStart = idx + len(marker) + len("REDACTED")
				goto next
			default:
				end++
			}
		}
		value = value[:idx] + marker + "REDACTED"
		searchStart = len(value)

	next:
	}
}
