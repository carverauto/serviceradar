package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

// submitResult is the sink for streamed inventory batches. It is a package
// variable so tests can capture what the plugin emits without a live host.
var submitResult = submitPluginResult

// runProxmoxCheck enumerates every configured target and streams inventory to
// the host one node at a time. Each node's guests are fetched, enriched, emitted
// as their own result, and then dropped before the next node is processed, so
// peak memory (and the per-result payload) stays bounded to a single node
// regardless of how many guests the cluster has. Partial progress survives a
// mid-run cancellation because every node's batch is submitted as it completes.
// It returns a small final status result carrying only aggregate counts.
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

		// Batch 1: the target's nodes (always a small set) + topology details.
		// Each batch's status summary reports the RUNNING cumulative total (not
		// the per-batch count) so the /services card shows a growing "N node(s),
		// M guest(s)" rather than a misleading "0 guest(s)" from the node batch.
		emitProxmoxBatch(observedAt, target, version, cluster, nodes, nil, warnings, &totals)

		if !cfg.includeGuests() {
			continue
		}

		// Batches 2..N: one per node. Fetch + enrich only that node's guests,
		// emit them, then let the slice fall out of scope so the conservative GC
		// reclaims it before the next node — peak memory is one node's worth.
		// Each node gets a hard time budget so one slow/remote node can't starve
		// the rest of the cluster of enumeration time within the poll window.
		remaining := cfg.MaxGuests
		for _, node := range nodes {
			if strings.TrimSpace(node.Node) == "" {
				continue
			}

			// Guest batches carry cluster + version (so the v2 guest identity can
			// still be minted) but NOT the node object — the node was already
			// emitted and counted in its own batch, and re-including it here would
			// double-count nodes and re-emit the node discovery.
			guests, truncated := fetchNodeGuestsEnriched(cfg, target, token, node.Node, remaining, nodeEnrichDeadline(), warnings)
			if len(guests) > 0 {
				emitProxmoxBatch(observedAt, target, version, cluster, nil, guests, warnings, &totals)
			}

			if cfg.MaxGuests > 0 {
				remaining -= len(guests)
				if remaining <= 0 || truncated {
					warnings["guests:limit"] = fmt.Sprintf("guest listing truncated at max_guests=%d", cfg.MaxGuests)
					break
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

// fetchTargetTopology fetches the small, bounded per-target data: version,
// cluster status, and the enriched node list. Returns nil nodes only when the
// node listing itself failed (a hard target error).
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

	nodes = annotateNodesWithClusterStatus(enrichNodes(cfg, target, token, nodes, warnings), cluster)

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
) {
	// Each batch must carry its OWN observation timestamp. service_status rows
	// are keyed by (timestamp, gateway_id, service_name); when every streamed
	// batch of one run shared the run-start observedAt, batch 1 (nodes)
	// inserted and every subsequent guest batch violated the primary key and
	// was dropped in results processing — so guest devices never ingested and
	// the card was stuck at the first batch's "N node(s), 0 guest(s)".
	observedAt = time.Now().UTC().Format(time.RFC3339Nano)

	discovery := sdk.NewDeviceDiscovery(discoverySource)
	discovery.ObservedAt = observedAt
	addNodeDiscoveries(discovery, target, nodes, cluster)
	addGuestDiscoveries(discovery, guests)

	resources := summarizeInventory(nodes, guests)
	summary := checkSummary{
		Nodes:             len(nodes),
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
		// Never let one batch's encode failure sink the whole run.
		return
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
	emitResourceEvents(result, details)
	emitProxmoxMetricTelemetry(pluginID, details)
	if len(discovery.Devices) > 0 {
		result.AddDeviceDiscovery(*discovery)
	}

	_ = submitResult(result)
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
