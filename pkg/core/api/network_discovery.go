package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errServerUnavailable              = errors.New("server unavailable")
	errSNMPCheckerDescUnavailable     = errors.New("snmp-checker descriptor unavailable")
	errSNMPCheckerConfigMissing       = errors.New("snmp-checker config missing after template seed")
	errDatabaseServiceUnavailableSNMP = errors.New("database service unavailable for SNMP preference resolution")
)

const snmpInterfacePollingPrefKeyPrefix = "prefs/snmp/interface-polling"
const snmpPrefManagedTargetPrefix = "ifpref_"

type snmpInterfacePollingPref struct {
	DeviceID  string     `json:"device_id"`
	IfIndex   int        `json:"if_index"`
	Enabled   bool       `json:"enabled"`
	UpdatedAt time.Time  `json:"updated_at"`
	UpdatedBy string     `json:"updated_by,omitempty"`
	KVKey     string     `json:"kv_key,omitempty"`
	Revision  uint64     `json:"revision,omitempty"`
	Found     bool       `json:"found,omitempty"`
	Error     string     `json:"error,omitempty"`
	StoredAt  *time.Time `json:"stored_at,omitempty"`
}

type snmpInterfaceID struct {
	DeviceID string `json:"device_id"`
	IfIndex  int    `json:"if_index"`
}

type snmpInterfacePollingPrefBatchRequest struct {
	Interfaces []snmpInterfaceID `json:"interfaces"`
}

type snmpInterfacePollingPrefBatchResponse struct {
	Results []snmpInterfacePollingPref `json:"results"`
}

type snmpInterfacePollingPrefPutRequest struct {
	DeviceID string `json:"device_id"`
	IfIndex  int    `json:"if_index"`
	Enabled  bool   `json:"enabled"`
}

type snmpInterfacePollingPrefPutResponse struct {
	Preference          snmpInterfacePollingPref `json:"preference"`
	SNMPTargetsRebuilt  bool                     `json:"snmp_targets_rebuilt"`
	SNMPTargetsError    string                   `json:"snmp_targets_error,omitempty"`
	SNMPTargetsKVKey    string                   `json:"snmp_targets_kv_key,omitempty"`
	SNMPTargetsRevision uint64                   `json:"snmp_targets_revision,omitempty"`
}

type snmpTargetsRebuildResponse struct {
	Updated           bool   `json:"updated"`
	KVKey             string `json:"kv_key"`
	ManagedTargets    int    `json:"managed_targets"`
	ManagedInterfaces int    `json:"managed_interfaces"`
	Devices           int    `json:"devices"`
	Revision          uint64 `json:"revision,omitempty"`
	Message           string `json:"message,omitempty"`
}

var (
	errSNMPPrefDeviceIDRequired = errors.New("device_id is required")
	errSNMPPrefIfIndexInvalid   = errors.New("if_index must be a positive integer")
)

func snmpInterfacePrefKVKey(deviceID string, ifIndex int) (string, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return "", errSNMPPrefDeviceIDRequired
	}
	if ifIndex <= 0 {
		return "", errSNMPPrefIfIndexInvalid
	}

	key := snmpInterfacePollingPrefKeyPrefix + "/" + deviceID + "/" + strconv.Itoa(ifIndex) + ".json"
	return identitymap.SanitizeKeyPath(key), nil
}

func resolveKVStoreIDFromRequest(r *http.Request) string {
	if r == nil {
		return ""
	}
	kvStoreID := r.URL.Query().Get("kv_store_id")
	if kvStoreID == "" {
		kvStoreID = r.URL.Query().Get("kvStore")
	}
	return strings.TrimSpace(kvStoreID)
}

// @Summary Batch get per-interface SNMP polling preferences
// @Description Returns per-interface SNMP polling preferences stored in KV.
// @Tags Admin
// @Accept json
// @Produce json
// @Param kv_store_id query string false "KV store identifier (default: local)"
// @Param request body snmpInterfacePollingPrefBatchRequest true "Interface identifiers"
// @Success 200 {object} snmpInterfacePollingPrefBatchResponse
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/admin/network/discovery/snmp-polling/batch [post]
func (s *APIServer) handleBatchGetSNMPInterfacePollingPrefs(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	kvStoreID := resolveKVStoreIDFromRequest(r)

	var req snmpInterfacePollingPrefBatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeAPIError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.Interfaces) == 0 {
		s.writeAPIError(w, http.StatusBadRequest, "interfaces is required")
		return
	}

	keys := make([]string, 0, len(req.Interfaces))
	keyByIndex := make(map[int]string, len(req.Interfaces))

	for idx, iface := range req.Interfaces {
		key, err := snmpInterfacePrefKVKey(iface.DeviceID, iface.IfIndex)
		if err != nil {
			continue
		}
		resolvedKey := s.qualifyKVKey(kvStoreID, key)
		keys = append(keys, resolvedKey)
		keyByIndex[idx] = resolvedKey
	}

	resp := snmpInterfacePollingPrefBatchResponse{
		Results: make([]snmpInterfacePollingPref, 0, len(req.Interfaces)),
	}

	entries, err := s.batchGetKV(ctx, kvStoreID, keys)
	if err != nil {
		s.logger.Error().Err(err).Msg("failed batch get interface polling preferences")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to load preferences from KV")
		return
	}

	for idx, iface := range req.Interfaces {
		record := snmpInterfacePollingPref{
			DeviceID: iface.DeviceID,
			IfIndex:  iface.IfIndex,
		}

		key := keyByIndex[idx]
		if key == "" {
			record.Error = "invalid device_id or if_index"
			resp.Results = append(resp.Results, record)
			continue
		}
		record.KVKey = key

		entry, ok := entries[key]
		if !ok || entry == nil || !entry.Found || len(entry.Value) == 0 {
			record.Found = false
			resp.Results = append(resp.Results, record)
			continue
		}

		record.Found = true
		record.Revision = entry.Revision
		record.StoredAt = nil

		var stored snmpInterfacePollingPref
		if err := json.Unmarshal(entry.Value, &stored); err != nil {
			record.Error = "stored value is not valid JSON"
			resp.Results = append(resp.Results, record)
			continue
		}

		record.Enabled = stored.Enabled
		record.UpdatedAt = stored.UpdatedAt
		record.UpdatedBy = stored.UpdatedBy

		resp.Results = append(resp.Results, record)
	}

	if err := s.encodeJSONResponse(w, resp); err != nil {
		s.logger.Error().Err(err).Msg("failed to encode interface polling prefs response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to encode response")
	}
}

// @Summary Set per-interface SNMP polling preference
// @Description Updates a per-interface SNMP polling preference in KV.
// @Tags Admin
// @Accept json
// @Produce json
// @Param kv_store_id query string false "KV store identifier (default: local)"
// @Param request body snmpInterfacePollingPrefPutRequest true "Preference update"
// @Success 200 {object} snmpInterfacePollingPref
// @Failure 400 {object} models.ErrorResponse "Invalid request"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/admin/network/discovery/snmp-polling [put]
func (s *APIServer) handlePutSNMPInterfacePollingPref(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	kvStoreID := resolveKVStoreIDFromRequest(r)

	var req snmpInterfacePollingPrefPutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeAPIError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	key, err := snmpInterfacePrefKVKey(req.DeviceID, req.IfIndex)
	if err != nil {
		s.writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	resolvedKey := s.qualifyKVKey(kvStoreID, key)

	user, _ := auth.GetUserFromContext(ctx)
	userEmail := ""
	if user != nil {
		userEmail = user.Email
	}

	record := snmpInterfacePollingPref{
		DeviceID:  req.DeviceID,
		IfIndex:   req.IfIndex,
		Enabled:   req.Enabled,
		UpdatedAt: time.Now().UTC(),
		UpdatedBy: userEmail,
		KVKey:     resolvedKey,
		Found:     true,
	}

	payload, err := json.Marshal(record)
	if err != nil {
		s.writeAPIError(w, http.StatusInternalServerError, "failed to encode preference")
		return
	}

	if err := s.putConfigToKV(ctx, kvStoreID, resolvedKey, payload); err != nil {
		s.logger.Error().Err(err).Str("key", resolvedKey).Msg("failed to persist interface polling preference")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to write preference to KV")
		return
	}

	resp := snmpInterfacePollingPrefPutResponse{
		Preference: record,
	}

	if kvKey, revision, err := s.rebuildSNMPCheckerTargetsFromPrefs(ctx, kvStoreID, userEmail); err == nil {
		resp.SNMPTargetsRebuilt = true
		resp.SNMPTargetsKVKey = kvKey
		resp.SNMPTargetsRevision = revision
	} else {
		resp.SNMPTargetsRebuilt = false
		resp.SNMPTargetsError = err.Error()
	}

	if err := s.encodeJSONResponse(w, resp); err != nil {
		s.logger.Error().Err(err).Msg("failed to encode preference response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to encode response")
	}
}

// @Summary Rebuild SNMP checker targets from interface preferences
// @Description Regenerates managed SNMP checker targets based on stored per-interface preferences.
// @Tags Admin
// @Accept json
// @Produce json
// @Param kv_store_id query string false "KV store identifier (default: local)"
// @Success 200 {object} snmpTargetsRebuildResponse
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/admin/network/discovery/snmp-polling/rebuild [post]
func (s *APIServer) handleRebuildSNMPCheckerTargets(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	kvStoreID := resolveKVStoreIDFromRequest(r)
	user, _ := auth.GetUserFromContext(ctx)
	userEmail := ""
	if user != nil {
		userEmail = user.Email
	}

	kvKey, revision, err := s.rebuildSNMPCheckerTargetsFromPrefs(ctx, kvStoreID, userEmail)
	if err != nil {
		s.logger.Error().Err(err).Msg("failed to rebuild SNMP checker targets")
		s.writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}

	resp := snmpTargetsRebuildResponse{
		Updated:  true,
		KVKey:    kvKey,
		Revision: revision,
	}
	if err := s.encodeJSONResponse(w, resp); err != nil {
		s.logger.Error().Err(err).Msg("failed to encode rebuild response")
		s.writeAPIError(w, http.StatusInternalServerError, "failed to encode response")
	}
}

type snmpPrefDeviceInfo struct {
	deviceID string
	deviceIP string
}

func (s *APIServer) rebuildSNMPCheckerTargetsFromPrefs(ctx context.Context, kvStoreID, writer string) (string, uint64, error) {
	if s == nil {
		return "", 0, errServerUnavailable
	}

	// Load existing SNMP checker config (required to avoid guessing node/security settings).
	const baseKey = "config/snmp-checker.json"
	kvKey := s.qualifyKVKey(kvStoreID, baseKey)
	entry, err := s.getKVEntry(ctx, kvStoreID, kvKey)
	if err != nil {
		return kvKey, 0, fmt.Errorf("failed to load snmp-checker config: %w", err)
	}

	if kvEntryMissing(entry) {
		desc, ok := config.ServiceDescriptorFor("snmp-checker")
		if !ok {
			return kvKey, 0, errSNMPCheckerDescUnavailable
		}
		if seedErr := s.seedConfigFromTemplate(ctx, desc, kvKey, kvStoreID); seedErr != nil {
			return kvKey, 0, fmt.Errorf("snmp-checker config missing and template seed failed: %w", seedErr)
		}
		entry, err = s.getKVEntry(ctx, kvStoreID, kvKey)
		if err != nil {
			return kvKey, 0, fmt.Errorf("failed to load seeded snmp-checker config: %w", err)
		}
		if kvEntryMissing(entry) {
			return kvKey, 0, errSNMPCheckerConfigMissing
		}
	}

	var cfg map[string]any
	if err := json.Unmarshal(entry.Value, &cfg); err != nil {
		return kvKey, entry.Revision, fmt.Errorf("snmp-checker config is invalid JSON: %w", err)
	}

	enabledPrefs, err := s.loadEnabledSNMPInterfacePrefs(ctx, kvStoreID)
	if err != nil {
		return kvKey, entry.Revision, err
	}

	deviceInfos, err := s.resolveSNMPPrefDevices(ctx, enabledPrefs)
	if err != nil {
		return kvKey, entry.Revision, err
	}

	version, community := s.resolveDefaultSNMPCredentialsFromMapper(ctx, kvStoreID)

	managedTargets := buildManagedSNMPTargets(deviceInfos, enabledPrefs, version, community)

	// Keep any existing non-managed targets.
	var kept []any
	if rawTargets, ok := cfg["targets"].([]any); ok {
		for _, item := range rawTargets {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			name, _ := m["name"].(string)
			if strings.HasPrefix(strings.ToLower(strings.TrimSpace(name)), snmpPrefManagedTargetPrefix) {
				continue
			}
			kept = append(kept, item)
		}
	}

	kept = append(kept, managedTargets...)
	cfg["targets"] = kept

	payload, err := json.Marshal(cfg)
	if err != nil {
		return kvKey, entry.Revision, fmt.Errorf("failed to encode updated snmp-checker config: %w", err)
	}

	if err := s.putConfigToKV(ctx, kvStoreID, kvKey, payload); err != nil {
		return kvKey, entry.Revision, fmt.Errorf("failed to write snmp-checker config: %w", err)
	}

	if writer == "" {
		writer = "system"
	}
	s.recordConfigMetadata(ctx, kvStoreID, kvKey, "user", writer)

	updated, err := s.getKVEntry(ctx, kvStoreID, kvKey)
	if err != nil || updated == nil {
		return kvKey, entry.Revision, nil
	}
	return kvKey, updated.Revision, nil
}

func (s *APIServer) loadEnabledSNMPInterfacePrefs(ctx context.Context, kvStoreID string) ([]snmpInterfacePollingPref, error) {
	prefix := identitymap.SanitizeKeyPath(snmpInterfacePollingPrefKeyPrefix) + "/"
	keys, err := s.listKVKeys(ctx, kvStoreID, prefix)
	if err != nil {
		return nil, fmt.Errorf("failed to list interface preference keys: %w", err)
	}
	if len(keys) == 0 {
		return nil, nil
	}

	entries, err := s.batchGetKV(ctx, kvStoreID, keys)
	if err != nil {
		return nil, fmt.Errorf("failed to load interface preferences: %w", err)
	}

	prefs := make([]snmpInterfacePollingPref, 0, len(keys))
	for _, key := range keys {
		entry, ok := entries[key]
		if !ok || entry == nil || !entry.Found || len(entry.Value) == 0 {
			continue
		}
		var pref snmpInterfacePollingPref
		if err := json.Unmarshal(entry.Value, &pref); err != nil {
			continue
		}
		if !pref.Enabled {
			continue
		}
		prefs = append(prefs, pref)
	}
	return prefs, nil
}

func (s *APIServer) resolveSNMPPrefDevices(ctx context.Context, prefs []snmpInterfacePollingPref) ([]snmpPrefDeviceInfo, error) {
	if len(prefs) == 0 {
		return nil, nil
	}
	if s.dbService == nil {
		return nil, errDatabaseServiceUnavailableSNMP
	}

	seen := make(map[string]struct{}, len(prefs))
	infos := make([]snmpPrefDeviceInfo, 0, len(prefs))
	for _, pref := range prefs {
		deviceID := strings.TrimSpace(pref.DeviceID)
		if deviceID == "" {
			continue
		}
		if _, ok := seen[deviceID]; ok {
			continue
		}
		seen[deviceID] = struct{}{}

		rows, err := s.dbService.ExecuteQuery(ctx,
			`SELECT device_ip FROM discovered_interfaces WHERE device_id = $1 ORDER BY timestamp DESC LIMIT 1`,
			deviceID,
		)
		if err != nil || len(rows) == 0 {
			continue
		}
		ip, _ := rows[0]["device_ip"].(string)
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		infos = append(infos, snmpPrefDeviceInfo{deviceID: deviceID, deviceIP: ip})
	}

	sort.Slice(infos, func(i, j int) bool {
		if infos[i].deviceIP == infos[j].deviceIP {
			return infos[i].deviceID < infos[j].deviceID
		}
		return infos[i].deviceIP < infos[j].deviceIP
	})

	return infos, nil
}

func (s *APIServer) resolveDefaultSNMPCredentialsFromMapper(ctx context.Context, kvStoreID string) (snmp.SNMPVersion, string) {
	key := s.qualifyKVKey(kvStoreID, "config/mapper.json")
	entry, err := s.getKVEntry(ctx, kvStoreID, key)
	if err != nil || entry == nil || !entry.Found || len(entry.Value) == 0 {
		return snmp.Version2c, ""
	}

	var doc map[string]any
	if err := json.Unmarshal(entry.Value, &doc); err != nil {
		return snmp.Version2c, ""
	}
	creds, _ := doc["default_credentials"].(map[string]any)
	versionRaw, _ := creds["version"].(string)
	community, _ := creds["community"].(string)
	versionRaw = strings.ToLower(strings.TrimSpace(versionRaw))
	switch versionRaw {
	case "v1":
		return snmp.Version1, strings.TrimSpace(community)
	case "v3":
		return snmp.Version3, strings.TrimSpace(community)
	default:
		return snmp.Version2c, strings.TrimSpace(community)
	}
}

func buildManagedSNMPTargets(devices []snmpPrefDeviceInfo, prefs []snmpInterfacePollingPref, version snmp.SNMPVersion, community string) []any {
	if len(devices) == 0 || len(prefs) == 0 {
		return nil
	}

	ifIndexesByDevice := make(map[string][]int, len(devices))
	for _, pref := range prefs {
		if pref.IfIndex <= 0 {
			continue
		}
		deviceID := strings.TrimSpace(pref.DeviceID)
		if deviceID == "" {
			continue
		}
		ifIndexesByDevice[deviceID] = append(ifIndexesByDevice[deviceID], pref.IfIndex)
	}

	managed := make([]any, 0, len(devices))
	for _, device := range devices {
		ifIndexes := ifIndexesByDevice[device.deviceID]
		if len(ifIndexes) == 0 {
			continue
		}
		sort.Ints(ifIndexes)
		ifIndexes = slicesCompact(ifIndexes)

		oidConfigs := make([]map[string]any, 0, len(ifIndexes)*2+1)
		oidConfigs = append(oidConfigs, map[string]any{
			"oid":   ".1.3.6.1.2.1.1.3.0",
			"name":  "sysUpTime",
			"type":  "gauge",
			"scale": 1.0,
		})
		for _, idx := range ifIndexes {
			oidConfigs = append(oidConfigs,
				map[string]any{
					"oid":   fmt.Sprintf(".1.3.6.1.2.1.2.2.1.10.%d", idx),
					"name":  fmt.Sprintf("ifInOctets_%d", idx),
					"type":  "counter",
					"scale": 1.0,
					"delta": true,
				},
				map[string]any{
					"oid":   fmt.Sprintf(".1.3.6.1.2.1.2.2.1.16.%d", idx),
					"name":  fmt.Sprintf("ifOutOctets_%d", idx),
					"type":  "counter",
					"scale": 1.0,
					"delta": true,
				},
			)
		}

		managed = append(managed, map[string]any{
			"name":      snmpPrefManagedTargetPrefix + sanitizeSNMPTargetName(device.deviceIP),
			"host":      device.deviceIP,
			"port":      161,
			"community": community,
			"version":   string(version),
			"interval":  "60s",
			"retries":   2,
			"oids":      oidConfigs,
		})
	}

	return managed
}

func sanitizeSNMPTargetName(host string) string {
	host = strings.TrimSpace(host)
	host = strings.ReplaceAll(host, ".", "_")
	host = strings.ReplaceAll(host, ":", "_")
	if host == "" {
		return "unknown"
	}
	return host
}

func slicesCompact(values []int) []int {
	if len(values) <= 1 {
		return values
	}
	out := values[:0]
	prev := 0
	for i, v := range values {
		if i == 0 || v != prev {
			out = append(out, v)
			prev = v
		}
	}
	return out
}

func (s *APIServer) listKVKeys(ctx context.Context, kvStoreID, prefix string) ([]string, error) {
	kvClient, closeFn, err := s.getKVClient(ctx, kvStoreID)
	if err != nil {
		return nil, err
	}
	defer closeFn()

	resp, err := kvClient.ListKeys(ctx, &proto.ListKeysRequest{Prefix: prefix})
	if err != nil {
		return nil, err
	}
	keys := resp.GetKeys()
	sort.Strings(keys)
	return keys, nil
}

func (s *APIServer) batchGetKV(ctx context.Context, kvStoreID string, keys []string) (map[string]*kvEntry, error) {
	results := make(map[string]*kvEntry, len(keys))
	if len(keys) == 0 {
		return results, nil
	}

	kvClient, closeFn, err := s.getKVClient(ctx, kvStoreID)
	if err != nil {
		return nil, err
	}
	defer closeFn()

	resp, err := kvClient.BatchGet(ctx, &proto.BatchGetRequest{Keys: keys})
	if err != nil {
		return nil, err
	}

	for _, item := range resp.GetResults() {
		results[item.GetKey()] = &kvEntry{
			Value:    item.GetValue(),
			Found:    item.GetFound(),
			Revision: item.GetRevision(),
		}
	}

	return results, nil
}
