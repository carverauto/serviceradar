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
	discovery := sdk.NewDeviceDiscovery(discoverySource)
	discovery.ObservedAt = now.Format(time.RFC3339Nano)
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

		addNodeDiscoveries(discovery, target, inventory.Nodes)
		addGuestDiscoveries(discovery, inventory.Guests)

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
	result.AddLabel("plugin_id", pluginID)
	emitResourceEvents(result, details)
	emitProxmoxMetricTelemetry(pluginID, details)
	if len(discovery.Devices) > 0 {
		result.AddDeviceDiscovery(*discovery)
	}

	return result, nil
}
