/*
 * Copyright 2025 Carver Automation Corporation.
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

package netbox

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
)

// parseTCPPorts parses TCP ports from the config credentials.
// It looks for a "tcp_ports" credential containing comma-separated port numbers.
// If not found or invalid, returns the default NetBox ports.
func parseTCPPorts(config *models.SourceConfig) []int {
	defaultPorts := []int{22, 80, 443, 3389, 445, 5985, 5986, 8080}

	portsStr, ok := config.Credentials["tcp_ports"]
	if !ok || portsStr == "" {
		return defaultPorts
	}

	var ports []int

	for _, portStr := range strings.Split(portsStr, ",") {
		portStr = strings.TrimSpace(portStr)
		if port, err := strconv.Atoi(portStr); err == nil && port > 0 && port <= 65535 {
			ports = append(ports, port)
		}
	}

	// If no valid ports were parsed, return defaults
	if len(ports) == 0 {
		return defaultPorts
	}

	return ports
}

// Fetch retrieves devices from NetBox for discovery purposes only.
// This method focuses purely on data discovery and does not perform state reconciliation.
func (n *NetboxIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, error) {
	resp, err := n.fetchDevices(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer n.closeResponse(resp)

	deviceResp, err := n.decodeResponse(resp)
	if err != nil {
		return nil, nil, err
	}

	// Process current devices from Netbox API
	data, ips, currentEvents := n.processDevices(ctx, deviceResp)

	n.Logger.Info().
		Int("devices_discovered", len(deviceResp.Results)).
		Int("sweep_results_generated", len(currentEvents)).
		Msg("Completed NetBox discovery operation")

	n.writeSweepConfig(ctx, ips)

	// Return the data for both KV store and sweep agents
	return data, currentEvents, nil
}

// Reconcile performs state reconciliation operations for NetBox.
// This method generates retraction events for devices that no longer exist in NetBox.
// It should only be called after sweep operations have completed.
func (n *NetboxIntegration) Reconcile(ctx context.Context) error {
	if n.Querier == nil {
		n.Logger.Info().Msg("NetBox querier not configured, skipping reconciliation")
		return nil
	}

	n.Logger.Info().Msg("Starting NetBox reconciliation operation")

	// Get current device states from ServiceRadar
	existingRadarDevices, err := n.Querier.GetDeviceStatesBySource(ctx, "netbox")
	if err != nil {
		n.Logger.Error().
			Err(err).
			Str("source", "netbox").
			Msg("Failed to query existing Netbox devices from ServiceRadar during reconciliation")

		return err
	}

	if len(existingRadarDevices) == 0 {
		n.Logger.Info().Msg("No existing NetBox device states found, skipping reconciliation")
		return nil
	}

	n.Logger.Info().
		Int("device_count", len(existingRadarDevices)).
		Str("source", "netbox").
		Msg("Successfully queried device states from ServiceRadar for reconciliation")

	// Fetch current devices from NetBox to identify retractions
	resp, err := n.fetchDevices(ctx)
	if err != nil {
		n.Logger.Error().
			Err(err).
			Msg("Failed to fetch current devices from NetBox during reconciliation")

		return err
	}
	defer n.closeResponse(resp)

	deviceResp, err := n.decodeResponse(resp)
	if err != nil {
		n.Logger.Error().
			Err(err).
			Msg("Failed to decode NetBox response during reconciliation")

		return err
	}

	// Process current devices to get current events
	_, _, currentEvents := n.processDevices(ctx, deviceResp)

	// Generate retraction events
	retractionEvents := n.generateRetractionEvents(currentEvents, existingRadarDevices)

	if len(retractionEvents) > 0 {
		n.Logger.Info().
			Int("retraction_count", len(retractionEvents)).
			Str("source", "netbox").
			Msg("Generated retraction events during reconciliation")

		// Send retraction events to the core service
		if n.ResultSubmitter != nil {
			if err := n.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents); err != nil {
				n.Logger.Error().
					Err(err).
					Int("retraction_count", len(retractionEvents)).
					Msg("Failed to submit retraction events to core service")

				return err
			}

			n.Logger.Info().
				Int("retraction_count", len(retractionEvents)).
				Msg("Successfully submitted retraction events to core service")
		} else {
			n.Logger.Warn().
				Int("retraction_count", len(retractionEvents)).
				Msg("ResultSubmitter not configured, retraction events not sent")
		}
	} else {
		n.Logger.Info().Msg("No retraction events needed for NetBox reconciliation")
	}

	n.Logger.Info().Msg("Successfully completed NetBox reconciliation")

	return nil
}

// generateRetractionEvents checks for devices that exist in ServiceRadar but not in the current Netbox fetch.
func (n *NetboxIntegration) generateRetractionEvents(
	currentEvents []*models.DeviceUpdate, existingDeviceStates []DeviceState) []*models.DeviceUpdate {
	// Create a map of current device IDs from the Netbox API for efficient lookup.
	currentDeviceIDs := make(map[string]struct{}, len(currentEvents))

	for _, event := range currentEvents {
		if integrationID, ok := event.Metadata["integration_id"]; ok {
			currentDeviceIDs[integrationID] = struct{}{}
		}
	}

	var retractionEvents []*models.DeviceUpdate

	now := time.Now()

	for _, state := range existingDeviceStates {
		// Extract the original integration_id from the metadata.
		netboxID, ok := state.Metadata["integration_id"].(string)
		if !ok {
			continue // Cannot determine retraction status.
		}

		// If a device that was previously discovered is not in the current list, it's considered retracted.
		if _, found := currentDeviceIDs[netboxID]; !found {
			n.Logger.Info().
				Str("netbox_id", netboxID).
				Str("ip", state.IP).
				Msg("Device no longer detected, generating retraction event")

			retractionEvent := &models.DeviceUpdate{
				DeviceID:    state.DeviceID,
				Source:      models.DiscoverySourceNetbox,
				IP:          state.IP,
				IsAvailable: false,
				Timestamp:   now,
				Metadata: map[string]string{
					"_deleted": "true",
				},
				AgentID:   n.Config.AgentID,
				PollerID:  n.Config.PollerID,
				Partition: n.Config.Partition,
			}

			retractionEvents = append(retractionEvents, retractionEvent)
		}
	}

	return retractionEvents
}

// fetchDevices sends the HTTP request to the NetBox API.
func (n *NetboxIntegration) fetchDevices(ctx context.Context) (*http.Response, error) {
	url := n.Config.Endpoint + "/api/dcim/devices/"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Token "+n.Config.Credentials["api_token"])
	req.Header.Set("Accept", "application/json")

	// Create a custom HTTP client with TLS configuration
	//nolint:gosec // Allow insecure TLS configuration for testing purposes
	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: n.Config.InsecureSkipVerify,
			},
		},
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode != http.StatusOK {
		err := resp.Body.Close()
		if err != nil {
			return nil, err
		}

		return nil, fmt.Errorf("%w: %d", errUnexpectedStatusCode, resp.StatusCode)
	}

	return resp, nil
}

// closeResponse closes the HTTP response body, logging any errors.
func (n *NetboxIntegration) closeResponse(resp *http.Response) {
	if err := resp.Body.Close(); err != nil {
		n.Logger.Warn().
			Err(err).
			Msg("Failed to close response body")
	}
}

// decodeResponse decodes the HTTP response into a DeviceResponse.
func (*NetboxIntegration) decodeResponse(resp *http.Response) (DeviceResponse, error) {
	var deviceResp DeviceResponse

	if err := json.NewDecoder(resp.Body).Decode(&deviceResp); err != nil {
		return DeviceResponse{}, err
	}

	return deviceResp, nil
}

// processDevices converts devices to KV data, extracts IPs, and returns the list of devices.
type netboxDeviceContext struct {
	device      *Device
	event       *models.DeviceUpdate
	keys        []identitymap.Key
	orderedKeys []identitymap.Key
	kvKey       string
	network     string
}

func (n *NetboxIntegration) processDevices(ctx context.Context, deviceResp DeviceResponse) (
	data map[string][]byte,
	ips []string,
	events []*models.DeviceUpdate,
) {
	if ctx == nil {
		ctx = context.Background()
	}

	data = make(map[string][]byte)
	ips = make([]string, 0, len(deviceResp.Results))
	events = make([]*models.DeviceUpdate, 0, len(deviceResp.Results))

	agentID := n.Config.AgentID
	pollerID := n.Config.PollerID
	partition := n.Config.Partition

	contexts := make([]netboxDeviceContext, 0, len(deviceResp.Results))

	now := time.Now()

	for i := range deviceResp.Results {
		var err error

		device := &deviceResp.Results[i]

		if device.PrimaryIP4.Address == "" {
			continue
		}

		ip, _, err := net.ParseCIDR(device.PrimaryIP4.Address)
		if err != nil {
			n.Logger.Warn().
				Err(err).
				Str("ip_address", device.PrimaryIP4.Address).
				Msg("Failed to parse IP address")

			continue
		}

		ipStr := ip.String()

		network := fmt.Sprintf("%s/32", ipStr)
		if n.ExpandSubnets {
			network = device.PrimaryIP4.Address
		}

		ips = append(ips, network)

		kvKey := fmt.Sprintf("%s/%s", agentID, ipStr)

		metadata := map[string]interface{}{
			"netbox_device_id": fmt.Sprintf("%d", device.ID),
			"role":             device.Role.Name,
			"site":             device.Site.Name,
		}

		hostname := device.Name
		deviceID := fmt.Sprintf("%s:%s", partition, ipStr)

		event := &models.DeviceUpdate{
			AgentID:   agentID,
			PollerID:  pollerID,
			Source:    models.DiscoverySourceNetbox,
			DeviceID:  deviceID,
			Partition: partition,
			IP:        ipStr,
			Hostname:  &hostname,
			Timestamp: now,
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   fmt.Sprintf("%d", device.ID),
			},
		}

		for k, v := range metadata {
			if str, ok := v.(string); ok {
				event.Metadata[k] = str
			} else {
				event.Metadata[k] = fmt.Sprintf("%v", v)
			}
		}

		keys := identitymap.BuildKeys(event)
		ordered := identitymap.PrioritizeKeys(keys)

		contexts = append(contexts, netboxDeviceContext{
			device:      device,
			event:       event,
			keys:        keys,
			orderedKeys: ordered,
			kvKey:       kvKey,
			network:     network,
		})
	}

	entries, fetchErr := n.prefetchCanonicalEntries(ctx, contexts)

	for _, ctxDevice := range contexts {
		var (
			record   *identitymap.Record
			revision uint64
		)

		if len(entries) != 0 {
			record, revision = n.resolveCanonicalRecord(entries, ctxDevice.orderedKeys)
		}

		if record == nil && fetchErr != nil {
			if fallback, rev := n.lookupCanonicalRecordDirect(ctx, ctxDevice.keys); fallback != nil {
				record = fallback
				revision = rev
			}
		}

		if record != nil {
			n.attachCanonicalMetadata(ctxDevice.event, record, revision)
		}

		metaJSON, err := json.Marshal(ctxDevice.event.Metadata)
		if err == nil {
			n.Logger.Debug().
				Str("metadata", string(metaJSON)).
				Msg("SweepResult metadata")
		}

		value, err := json.Marshal(ctxDevice.event)
		if err != nil {
			n.Logger.Error().
				Err(err).
				Int("device_id", ctxDevice.device.ID).
				Msg("Failed to marshal device")

			continue
		}

		data[ctxDevice.kvKey] = value
		events = append(events, ctxDevice.event)
	}

	return data, ips, events
}

func (n *NetboxIntegration) prefetchCanonicalEntries(ctx context.Context, contexts []netboxDeviceContext) (map[string]*proto.BatchGetEntry, error) {
	if n.KvClient == nil || len(contexts) == 0 {
		return nil, nil
	}

	if ctx == nil {
		ctx = context.Background()
	}

	seenPaths := make(map[string]struct{})
	paths := make([]string, 0, len(contexts)*3)

	for _, ctxDevice := range contexts {
		for _, key := range ctxDevice.orderedKeys {
			sanitized := key.KeyPath(identitymap.DefaultNamespace)
			if _, ok := seenPaths[sanitized]; ok {
				continue
			}
			seenPaths[sanitized] = struct{}{}
			paths = append(paths, sanitized)
		}
	}

	if len(paths) == 0 {
		return nil, nil
	}

	const chunkSize = 256
	entries := make(map[string]*proto.BatchGetEntry, len(paths))
	var firstErr error

	for start := 0; start < len(paths); start += chunkSize {
		end := start + chunkSize
		if end > len(paths) {
			end = len(paths)
		}

		resp, err := n.KvClient.BatchGet(ctx, &proto.BatchGetRequest{Keys: paths[start:end]})
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			n.Logger.Debug().
				Err(err).
				Int("batch_start", start).
				Int("batch_size", end-start).
				Msg("NetBox identity map prefetch failed")
			continue
		}

		for _, entry := range resp.GetResults() {
			if entry == nil {
				continue
			}
			entries[entry.GetKey()] = entry
		}
	}

	return entries, firstErr
}

func (n *NetboxIntegration) resolveCanonicalRecord(entries map[string]*proto.BatchGetEntry, ordered []identitymap.Key) (*identitymap.Record, uint64) {
	if len(entries) == 0 || len(ordered) == 0 {
		return nil, 0
	}

	for _, key := range ordered {
		sanitized := key.KeyPath(identitymap.DefaultNamespace)
		entry, ok := entries[sanitized]
		if !ok || !entry.GetFound() || len(entry.GetValue()) == 0 {
			continue
		}

		record, err := identitymap.UnmarshalRecord(entry.GetValue())
		if err != nil {
			n.Logger.Debug().
				Err(err).
				Str("identity_kind", key.Kind.String()).
				Str("identity_value", key.Value).
				Msg("Failed to unmarshal canonical identity record")
			continue
		}

		n.Logger.Debug().
			Str("identity_kind", key.Kind.String()).
			Str("identity_value", key.Value).
			Str("canonical_device_id", record.CanonicalDeviceID).
			Msg("Resolved canonical identity for NetBox device")

		return record, entry.GetRevision()
	}

	return nil, 0
}

func (n *NetboxIntegration) lookupCanonicalRecordDirect(ctx context.Context, keys []identitymap.Key) (*identitymap.Record, uint64) {
	if n.KvClient == nil || len(keys) == 0 {
		return nil, 0
	}

	if ctx == nil {
		ctx = context.Background()
	}

	ordered := identitymap.PrioritizeKeys(keys)
	if len(ordered) == 0 {
		return nil, 0
	}

	seenPaths := make(map[string]struct{}, len(ordered))
	paths := make([]string, 0, len(ordered))
	for _, key := range ordered {
		sanitized := key.KeyPath(identitymap.DefaultNamespace)
		if _, ok := seenPaths[sanitized]; ok {
			continue
		}
		seenPaths[sanitized] = struct{}{}
		paths = append(paths, sanitized)
	}

	resp, err := n.KvClient.BatchGet(ctx, &proto.BatchGetRequest{Keys: paths})
	if err != nil {
		n.Logger.Debug().Err(err).Msg("NetBox identity map lookup failed")
		return nil, 0
	}

	entries := make(map[string]*proto.BatchGetEntry, len(resp.GetResults()))
	for _, entry := range resp.GetResults() {
		if entry == nil {
			continue
		}
		entries[entry.GetKey()] = entry
	}

	return n.resolveCanonicalRecord(entries, ordered)
}

func (n *NetboxIntegration) attachCanonicalMetadata(event *models.DeviceUpdate, record *identitymap.Record, revision uint64) {
	if event == nil || record == nil {
		return
	}

	if event.Metadata == nil {
		event.Metadata = make(map[string]string)
	}

	event.Metadata["canonical_device_id"] = record.CanonicalDeviceID
	if record.Partition != "" {
		event.Metadata["canonical_partition"] = record.Partition
	}
	if record.MetadataHash != "" {
		event.Metadata["canonical_metadata_hash"] = record.MetadataHash
	}
	if revision != 0 {
		event.Metadata["canonical_revision"] = strconv.FormatUint(revision, 10)
	}

	if hostname, ok := record.Attributes["hostname"]; ok && hostname != "" {
		event.Metadata["canonical_hostname"] = hostname
	}
}

// writeSweepConfig generates and writes the sweep Config to KV.
func (n *NetboxIntegration) writeSweepConfig(ctx context.Context, ips []string) {
	if n.KvClient == nil {
		n.Logger.Warn().Msg("KV client not configured; skipping sweep config write")
		return
	}

	// Apply blacklist filtering to IPs before creating sweep config
	if len(n.Config.NetworkBlacklist) > 0 {
		n.Logger.Info().
			Int("original_ip_count", len(ips)).
			Strs("blacklist_cidrs", n.Config.NetworkBlacklist).
			Msg("Applying network blacklist filtering to NetBox IPs")

		filteredIPs, err := models.FilterIPsWithBlacklist(ips, n.Config.NetworkBlacklist)
		if err != nil {
			n.Logger.Error().
				Err(err).
				Msg("Failed to apply network blacklist filtering, using original IPs")
		} else {
			ips = filteredIPs
		}

		n.Logger.Info().
			Int("filtered_ip_count", len(ips)).
			Msg("Applied network blacklist filtering")
	}

	// AgentID to be used for the sweep config key.
	// We prioritize the agent_id set on the source config itself.
	agentIDForConfig := n.Config.AgentID
	if agentIDForConfig == "" {
		// As a fallback, we could use ServerName, but logging a warning is better
		// to encourage explicit configuration.
		n.Logger.Warn().
			Str("source", "netbox").
			Msg("agent_id not set for Netbox source. Sweep config key may be incorrect")
		// If you need a fallback, you can use: agentIDForConfig = n.ServerName

		return // Or simply return to avoid writing a config with an unpredictable key
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", agentIDForConfig)

	// Clean up old sweep config to remove any stale data before writing new config
	n.Logger.Info().
		Str("config_key", configKey).
		Msg("Cleaning up old sweep config from KV store")

	if _, delErr := n.KvClient.Delete(ctx, &proto.DeleteRequest{
		Key: configKey,
	}); delErr != nil {
		n.Logger.Debug().
			Err(delErr).
			Str("config_key", configKey).
			Msg("Failed to delete old sweep config (may not exist)")
	} else {
		n.Logger.Info().
			Str("config_key", configKey).
			Msg("Successfully cleaned up old sweep config")
	}

	// Create minimal sweep config with only networks (file config is authoritative for everything else)
	n.Logger.Info().Msg("Creating networks-only sweep config for KV")

	sweepConfig := models.SweepConfig{
		Networks: ips,
	}

	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		n.Logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")

		return
	}

	_, err = n.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	n.Logger.Info().
		Str("config_key", configKey).
		Str("config", string(configJSON)).
		Msg("Writing sweep config")

	if err != nil {
		n.Logger.Error().
			Err(err).
			Str("config_key", configKey).
			Msg("Failed to write sweep config")

		return
	}

	n.Logger.Info().
		Str("config_key", configKey).
		Msg("Successfully wrote sweep config")
}
