package main

import (
	"fmt"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func runProxmoxCheck(cfg Config) (*pluginResult, error) {
	cfg.applyDefaults()
	applyHTTPClientLimits(cfg)

	targets := cfg.effectiveTargets()
	if len(targets) == 0 {
		return nil, errMissingTarget
	}

	now := time.Now().UTC()
	details := proxmoxDetails{
		Schema:  "serviceradar.proxmox_enrichment.v1",
		Targets: make([]proxmoxTarget, 0, len(targets)),
		Errors:  map[string]string{},
	}

	for _, target := range targets {
		inventory, err := fetchTargetInventory(cfg, target)
		if err != nil {
			details.Errors[target.safeName()] = sanitizeError(err)
			continue
		}

		details.Targets = append(details.Targets, proxmoxTarget{
			BaseURL:  target.redactedBaseURL(),
			Version:  inventory.Version,
			Cluster:  inventory.Cluster,
			Nodes:    inventory.Nodes,
			Guests:   inventory.Guests,
			Summary:  inventory.Summary,
			Warnings: inventory.Warnings,
			Meta:     targetMetadata(target),
		})
		details.Summary.Targets++
		details.Summary.Nodes += len(inventory.Nodes)
		details.Summary.Guests += len(inventory.Guests)
		details.Summary.QEMU += countGuests(inventory.Guests, "qemu")
		details.Summary.LXC += countGuests(inventory.Guests, "lxc")
		details.Summary.Storage += inventory.Summary.StorageCount
		details.Summary.NetworkInterfaces += inventory.Summary.NetworkInterfaceCount
		details.Summary.Disks += inventory.Summary.DiskCount
		details.Summary.CephEnabledNodes += inventory.Summary.CephEnabledNodes
		details.Summary.Bottleneck += inventory.Summary.ResourceBottleneck
		details.ResourceSummary = mergeResourceSummary(details.ResourceSummary, inventory.Summary)
	}

	if details.Summary.Targets == 0 {
		return nil, fmt.Errorf("all Proxmox targets failed: %s", joinErrors(details.Errors))
	}

	if len(details.Errors) == 0 {
		details.Errors = nil
	}

	body, err := marshalProxmoxDetails(details)
	if err != nil {
		return nil, fmt.Errorf("encode details: %w", err)
	}

	status := sdk.StatusOK
	summary := fmt.Sprintf(
		"Proxmox inventory: %d target(s), %d node(s), %d guest(s)",
		details.Summary.Targets,
		details.Summary.Nodes,
		details.Summary.Guests,
	)
	if len(details.Errors) > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d target error(s)", len(details.Errors))
	}
	if details.Summary.Bottleneck > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d resource bottleneck(s)", details.Summary.Bottleneck)
	}

	result := newPluginResult(status, summary)
	result.Details = string(body)
	result.ObservedAt = now.Format(time.RFC3339Nano)
	result.AddMetric("proxmox_targets", float64(details.Summary.Targets), "count", nil)
	result.AddMetric("proxmox_nodes", float64(details.Summary.Nodes), "count", nil)
	result.AddMetric("proxmox_guests", float64(details.Summary.Guests), "count", nil)
	result.AddMetric("proxmox_qemu_guests", float64(details.Summary.QEMU), "count", nil)
	result.AddMetric("proxmox_lxc_guests", float64(details.Summary.LXC), "count", nil)
	result.AddMetric("proxmox_storage", float64(details.Summary.Storage), "count", nil)
	result.AddMetric("proxmox_network_interfaces", float64(details.Summary.NetworkInterfaces), "count", nil)
	result.AddMetric("proxmox_disks", float64(details.Summary.Disks), "count", nil)
	result.AddMetric("proxmox_ceph_enabled_nodes", float64(details.Summary.CephEnabledNodes), "count", nil)
	result.AddMetric("proxmox_ceph_warn_nodes", float64(details.ResourceSummary.CephWarnNodes), "count", sdk.Thresholds(1, 1))
	result.AddMetric("proxmox_ceph_error_nodes", float64(details.ResourceSummary.CephErrorNodes), "count", sdk.Thresholds(1, 1))
	result.AddMetric("proxmox_node_cpu_ratio_max", details.ResourceSummary.MaxNodeCPURatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_node_mem_ratio_max", details.ResourceSummary.MaxNodeMemRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_node_io_wait_ratio_max", details.ResourceSummary.MaxNodeIOWaitRatio, "ratio", sdk.Thresholds(0.20, 0.40))
	result.AddMetric("proxmox_node_storage_ratio_max", details.ResourceSummary.MaxNodeStorageRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_cpu_ratio_max", details.ResourceSummary.MaxGuestCPURatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_mem_ratio_max", details.ResourceSummary.MaxGuestMemRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_disk_ratio_max", details.ResourceSummary.MaxGuestDiskRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddLabel("plugin_id", pluginID)

	return result, nil
}
