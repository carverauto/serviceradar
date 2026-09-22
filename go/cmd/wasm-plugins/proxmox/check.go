package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// submitResult is the sink for streamed inventory batches. It is a package
// variable so tests can capture what the plugin emits without a live host.
var submitResult = submitPluginResult

// clusterFingerprint identifies a cluster by its sorted member node names so
// duplicate targets pointing at the same cluster enumerate it only once.
func clusterFingerprint(nodes []proxmoxNode) string {
	names := make([]string, 0, len(nodes))
	for _, node := range nodes {
		names = append(names, strings.ToLower(strings.TrimSpace(node.Node)))
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

// runProxmoxCheck submits all hosts before guest enrichment so slow guest
// probes cannot prevent host inventory progress. Guest batches carry their
// owning host in details for downstream identity resolution, but do not count
// it again or repeat its discovery and telemetry. Only one node's guests are
// retained at a time. Encode or submission failures stop the run.
func runProxmoxCheck(cfg Config) (*pluginResult, error) {
	cfg.applyDefaults()
	applyHTTPClientLimits(cfg)

	targets := cfg.effectiveTargets()
	if len(targets) == 0 {
		return nil, errMissingTarget
	}

	now := time.Now().UTC()
	observedAt := now.Format(time.RFC3339Nano)

	var totals checkSummary
	targetErrors := map[string]string{}
	// A credential rule commonly materializes one target per discovered PVE
	// host, so several targets can point at the SAME cluster. Enumerating it
	// once per target multiplied every node/guest count and re-emitted every
	// discovery N times. Fingerprint the cluster by its member node names and
	// enumerate each cluster once per run.
	seenClusters := map[string]bool{}

	for _, target := range targets {
		token := normalizeProxmoxAPIToken(firstNonEmpty(target.APIToken, cfg.APIToken))
		if token == "" {
			targetErrors[target.safeName()] = errMissingToken.Error()
			continue
		}

		version, cluster, nodes, warnings := fetchTargetTopology(cfg, target, token)
		if nodes == nil {
			targetErrors[target.safeName()] = firstNonEmpty(warnings["nodes"], "fetch nodes failed")
			continue
		}

		if fp := clusterFingerprint(nodes); seenClusters[fp] {
			continue
		} else {
			seenClusters[fp] = true
		}
		totals.Targets++

		nodes = annotateNodesWithClusterStatus(enrichNodes(cfg, target, token, nodes, warnings), cluster)
		if err := emitProxmoxBatch(observedAt, target, version, cluster, nodes, nil, warnings, &totals); err != nil {
			return nil, err
		}
		if !cfg.includeGuests() {
			continue
		}

		remaining := cfg.MaxGuests
		for _, node := range nodes {
			if strings.TrimSpace(node.Node) == "" {
				continue
			}

			var guests []proxmoxGuest
			if cfg.MaxGuests <= 0 || remaining > 0 {
				var truncated bool
				guests, truncated = fetchNodeGuestsEnriched(cfg, target, token, node.Node, remaining, nodeEnrichDeadline(), warnings)
				if cfg.MaxGuests > 0 {
					remaining -= len(guests)
					if remaining <= 0 || truncated {
						remaining = 0
						warnings["guests:limit"] = fmt.Sprintf("guest listing truncated at max_guests=%d", cfg.MaxGuests)
					}
				}
			}

			if len(guests) > 0 {
				if err := emitProxmoxBatch(observedAt, target, version, cluster, []proxmoxNode{node}, guests, warnings, &totals); err != nil {
					return nil, err
				}
			}
		}
	}

	if totals.Targets == 0 {
		return nil, fmt.Errorf("all Proxmox targets failed: %s", joinErrors(targetErrors))
	}

	status := sdk.StatusOK
	summary := fmt.Sprintf(
		"Proxmox inventory: %d target(s), %d node(s), %d guest(s)",
		totals.Targets,
		totals.Nodes,
		totals.Guests,
	)
	if len(targetErrors) > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d target error(s)", len(targetErrors))
	}
	if totals.Bottleneck > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d resource bottleneck(s)", totals.Bottleneck)
	}

	result := newPluginResult(status, summary)
	result.ObservedAt = observedAt
	result.AddLabel("plugin_id", pluginID)
	return result, nil
}

func fetchTargetTopology(cfg Config, target Target, token string) (*proxmoxVersion, []proxmoxClusterNode, []proxmoxNode, map[string]string) {
	warnings := map[string]string{}

	var version *proxmoxVersion
	if v, err := fetchVersion(cfg, target, token); err != nil {
		warnings["version"] = sanitizeError(err)
	} else {
		version = &v
	}

	// Identity contract: the enrichment ingestor derives the versioned
	// integration identity from the cluster-status entry of type "cluster",
	// node names, and guest type+vmid. Keep the cluster attached to every batch
	// so per-node guest batches can still mint the v2 identity.
	var cluster []proxmoxClusterNode
	if c, err := fetchClusterStatus(cfg, target, token); err != nil {
		warnings["cluster_status"] = sanitizeError(err)
	} else {
		cluster = c
	}

	nodes, err := fetchNodes(cfg, target, token)
	if err != nil {
		warnings["nodes"] = sanitizeError(err)
		return version, cluster, nil, warnings
	}

	return version, cluster, nodes, warnings
}

// nodeEnrichBudget bounds how long a single node's guest enrichment may run
// before the remaining guests are emitted without runtime detail and the loop
// moves on. This keeps one slow or unreachable node from consuming the whole
// config-poll window and starving later nodes of any scan at all.
const nodeEnrichBudget = 90 * time.Second

func nodeEnrichDeadline() time.Time {
	return time.Now().Add(nodeEnrichBudget)
}

// fetchNodeGuestsEnriched fetches and enriches only the guests on a single node.
// budget is the remaining max_guests allowance for the target; truncated is true
// when that allowance was hit while listing this node. deadline caps the
// per-node enrichment time.
func fetchNodeGuestsEnriched(cfg Config, target Target, token, node string, budget int, deadline time.Time, warnings map[string]string) ([]proxmoxGuest, bool) {
	resources := make([]proxmoxResource, 0)
	truncated := false

	for _, kind := range []string{"qemu", "lxc"} {
		got, err := fetchNodeGuests(cfg, target, token, node, kind)
		if err != nil {
			warnings[fmt.Sprintf("node:%s:%s_guests", node, kind)] = sanitizeError(err)
			continue
		}

		resources, truncated = appendGuestResourcesWithinLimit(resources, got, budget)
		if truncated {
			break
		}
	}

	return enrichGuests(cfg, target, token, resources, deadline, warnings), truncated
}

// emitProxmoxBatch builds and submits one self-contained inventory result for a
// bounded slice of nodes and/or guests. It folds the batch into the running
// `totals` and reports those cumulative counts in the result status summary.
func emitProxmoxBatch(
	observedAt string,
	target Target,
	version *proxmoxVersion,
	cluster []proxmoxClusterNode,
	nodes []proxmoxNode,
	guests []proxmoxGuest,
	warnings map[string]string,
	totals *checkSummary,
) error {
	// Each batch must carry its OWN observation timestamp. service_status rows
	// are keyed by (timestamp, gateway_id, service_name); when every streamed
	// batch of one run shared the run-start observedAt, batch 1 (nodes)
	// inserted and every subsequent guest batch violated the primary key and
	// was dropped in results processing — so guest devices never ingested and
	// the card was stuck at the first batch's "N node(s), 0 guest(s)".
	observedAt = time.Now().UTC().Format(time.RFC3339Nano)

	newNodes := nodes
	if len(guests) > 0 {
		newNodes = nil
	}

	discovery := sdk.NewDeviceDiscovery(discoverySource)
	discovery.ObservedAt = observedAt
	addNodeDiscoveries(discovery, target, newNodes, cluster, warnings)
	addGuestDiscoveries(discovery, guests, cluster, warnings)

	resources := summarizeInventory(newNodes, guests)
	summary := checkSummary{
		Nodes:             len(newNodes),
		Guests:            len(guests),
		QEMU:              countGuests(guests, "qemu"),
		LXC:               countGuests(guests, "lxc"),
		Storage:           resources.StorageCount,
		NetworkInterfaces: resources.NetworkInterfaceCount,
		Disks:             resources.DiskCount,
		CephEnabledNodes:  resources.CephEnabledNodes,
		Bottleneck:        resources.ResourceBottleneck,
	}
	accumulateSummary(totals, summary)

	details := proxmoxDetails{
		Schema: "serviceradar.proxmox_enrichment.v1",
		Targets: []proxmoxTarget{
			{
				BaseURL:  target.redactedBaseURL(),
				Version:  version,
				Cluster:  cluster,
				Nodes:    nodes,
				Guests:   guests,
				Summary:  resources,
				Warnings: nilIfEmpty(warnings),
				Meta:     targetMetadata(target),
			},
		},
		Summary:         summary,
		ResourceSummary: resources,
	}

	body, err := marshalProxmoxDetails(details)
	if err != nil {
		return fmt.Errorf("encode Proxmox inventory batch: %w", err)
	}

	batchSummary := fmt.Sprintf(
		"Proxmox inventory: %d node(s), %d guest(s)",
		totals.Nodes,
		totals.Guests,
	)
	result := newPluginResult(sdk.StatusOK, batchSummary)
	result.ObservedAt = observedAt
	result.AddLabel("plugin_id", pluginID)
	result.Details = string(body)
	details.Targets[0].Nodes = newNodes
	emitResourceEvents(result, details)
	emitProxmoxMetricTelemetry(pluginID, details)
	if len(discovery.Devices) > 0 {
		result.AddDeviceDiscovery(*discovery)
	}

	if err := submitResult(result); err != nil {
		return fmt.Errorf("submit Proxmox inventory batch: %w", err)
	}
	return nil
}

func accumulateSummary(acc *checkSummary, add checkSummary) {
	acc.Nodes += add.Nodes
	acc.Guests += add.Guests
	acc.QEMU += add.QEMU
	acc.LXC += add.LXC
	acc.Storage += add.Storage
	acc.NetworkInterfaces += add.NetworkInterfaces
	acc.Disks += add.Disks
	acc.CephEnabledNodes += add.CephEnabledNodes
	acc.Bottleneck += add.Bottleneck
}
