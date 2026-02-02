package agent

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/pkg/agentgateway"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultArmisPageSize    = 100
	defaultSyncRunTimeout   = 10 * time.Minute
	syncServiceType         = "sync"
	syncServiceName         = "sync"
	syncMetaKey             = "sync_meta"
	armisSourceType         = "armis"
	armisAccessTokenPath    = "/api/v1/access_token/"
	armisSearchPath         = "/api/v1/search/"
	armisAuthHeaderTemplate = "Bearer %s"
)

var (
	errSyncRuntimeNoContext         = errors.New("sync runtime requires context")
	errUnsupportedSyncSourceType    = errors.New("unsupported sync source type")
	errArmisTokenRequestFailed      = errors.New("armis token request failed")
	errArmisTokenMissingAccessToken = errors.New("armis token response missing access_token")
	errArmisSearchFailed            = errors.New("armis search failed")
)

// SyncRuntime executes integration sources delivered via GetConfig.
type SyncRuntime struct {
	server  *Server
	gateway *agentgateway.GatewayClient
	logger  logger.Logger

	mu      sync.Mutex
	ctx     context.Context
	sources map[string]*syncSourceRunner
}

type syncSourceRunner struct {
	key    string
	hash   string
	config models.SourceConfig
	cancel context.CancelFunc

	mu       sync.Mutex
	inflight bool
}

type syncConfigPayload struct {
	AgentID string                         `json:"agent_id"`
	Sources map[string]models.SourceConfig `json:"sources"`
}

type armisDevice struct {
	ID              int       `json:"id"`
	IPAddress       string    `json:"ipAddress"`
	MacAddress      string    `json:"macAddress"`
	Name            string    `json:"name"`
	Type            string    `json:"type"`
	Category        string    `json:"category"`
	Manufacturer    string    `json:"manufacturer"`
	Model           string    `json:"model"`
	OperatingSystem string    `json:"operatingSystem"`
	FirstSeen       time.Time `json:"firstSeen"`
	LastSeen        time.Time `json:"lastSeen"`
	RiskLevel       int       `json:"riskLevel"`
	Boundaries      string    `json:"boundaries"`
	Tags            []string  `json:"tags"`
}

type armisSearchResponse struct {
	Data struct {
		Count   int           `json:"count"`
		Next    int           `json:"next"`
		Prev    interface{}   `json:"prev"`
		Results []armisDevice `json:"results"`
		Total   int           `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

type armisTokenResponse struct {
	Data struct {
		AccessToken string `json:"access_token"`
	} `json:"data"`
	Success bool `json:"success"`
}

// NewSyncRuntime builds the integration sync runtime for an agent.
func NewSyncRuntime(server *Server, gateway *agentgateway.GatewayClient, log logger.Logger) *SyncRuntime {
	return &SyncRuntime{
		server:  server,
		gateway: gateway,
		logger:  log,
		sources: make(map[string]*syncSourceRunner),
	}
}

// SetContext sets the base context for sync runners (called from PushLoop.Start).
func (r *SyncRuntime) SetContext(ctx context.Context) {
	r.mu.Lock()
	r.ctx = ctx
	r.mu.Unlock()
}

// ApplyConfig parses sync sources from the gateway payload and starts/stops runners.
func (r *SyncRuntime) ApplyConfig(configJSON []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.ctx == nil {
		r.logger.Warn().Err(errSyncRuntimeNoContext).Msg("Skipping sync runtime config")
		return
	}

	if !syncRuntimeEnabled(r.server.config) {
		r.stopAllLocked()
		return
	}

	sources, err := parseSyncSources(configJSON)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to parse sync sources from config")
		return
	}

	if len(sources) == 0 {
		r.stopAllLocked()
		return
	}

	// Stop removed sources.
	for key, runner := range r.sources {
		if _, ok := sources[key]; !ok {
			runner.cancel()
			delete(r.sources, key)
		}
	}

	for key, source := range sources {
		if !isSupportedSource(source.Type) {
			r.logger.Warn().Str("source", key).Str("type", source.Type).
				Msg("Skipping unsupported sync source type")
			continue
		}

		if strings.TrimSpace(source.Endpoint) == "" {
			r.logger.Warn().Str("source", key).Msg("Skipping sync source without endpoint")
			continue
		}

		hash := syncSourceHash(source)
		if existing, ok := r.sources[key]; ok {
			if existing.hash == hash {
				continue
			}
			existing.cancel()
			delete(r.sources, key)
		}

		r.sources[key] = r.startSourceLocked(key, source, hash)
	}
}

func (r *SyncRuntime) stopAllLocked() {
	for key, runner := range r.sources {
		runner.cancel()
		delete(r.sources, key)
	}
}

func (r *SyncRuntime) startSourceLocked(key string, source models.SourceConfig, hash string) *syncSourceRunner {
	ctx, cancel := context.WithCancel(r.ctx)
	runner := &syncSourceRunner{
		key:    key,
		hash:   hash,
		config: source,
		cancel: cancel,
	}

	go r.runSource(ctx, runner)
	return runner
}

func (r *SyncRuntime) runSource(ctx context.Context, runner *syncSourceRunner) {
	pollInterval := time.Duration(runner.config.PollInterval)
	discoveryInterval := time.Duration(runner.config.DiscoveryInterval)

	if pollInterval <= 0 && discoveryInterval <= 0 {
		r.logger.Warn().Str("source", runner.key).Msg("Sync source has no intervals configured")
		return
	}

	// Run an initial discovery immediately.
	r.executeRun(ctx, runner, "discovery")

	if discoveryInterval > 0 {
		ticker := time.NewTicker(discoveryInterval)
		defer ticker.Stop()

		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					r.executeRun(ctx, runner, "discovery")
				}
			}
		}()
	}

	if pollInterval > 0 && pollInterval != discoveryInterval {
		ticker := time.NewTicker(pollInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.executeRun(ctx, runner, "poll")
			}
		}
	}

	<-ctx.Done()
}

func (r *SyncRuntime) executeRun(ctx context.Context, runner *syncSourceRunner, runKind string) {
	if !runner.tryStart() {
		r.logger.Debug().Str("source", runner.key).Msg("Sync run skipped (in progress)")
		return
	}
	defer runner.finish()

	runID := uuid.NewString()
	runCtx, cancel := context.WithTimeout(ctx, defaultSyncRunTimeout)
	defer cancel()

	start := time.Now()
	count, err := r.runSourceOnce(runCtx, runner, runKind, runID)
	duration := time.Since(start)

	logEvent := r.logger.Info()
	if err != nil {
		logEvent = r.logger.Error().Err(err)
	}

	logEvent.Str("source", runner.key).
		Str("type", runner.config.Type).
		Str("run_id", runID).
		Str("kind", runKind).
		Int("device_count", count).
		Dur("duration", duration).
		Msg("Sync run completed")
}

func (r *SyncRuntime) runSourceOnce(
	ctx context.Context,
	runner *syncSourceRunner,
	_ string,
	runID string,
) (int, error) {
	sourceType := strings.ToLower(strings.TrimSpace(runner.config.Type))
	switch sourceType {
	case armisSourceType:
		return r.runArmisSync(ctx, runner, runID)
	default:
		return 0, fmt.Errorf("%w: %s", errUnsupportedSyncSourceType, sourceType)
	}
}

func (r *SyncRuntime) runArmisSync(
	ctx context.Context,
	runner *syncSourceRunner,
	runID string,
) (int, error) {
	client := newArmisClient(runner.config)
	queries := runner.config.Queries
	if len(queries) == 0 {
		queries = []models.QueryConfig{{}}
	}

	token, err := client.accessToken(ctx, runner.config.Credentials)
	if err != nil {
		return 0, err
	}

	pageSize := armisPageSize(runner.config)
	updates := make([]map[string]interface{}, 0, pageSize*len(queries))

	for _, query := range queries {
		queryString := query.Query
		queryLabel := query.Label

		from := 0
		for {
			resp, err := client.search(ctx, token, queryString, from, pageSize)
			if err != nil {
				return len(updates), err
			}

			filtered := filterArmisDevices(resp.Data.Results, runner.config.NetworkBlacklist)
			for _, device := range filtered {
				update := buildArmisUpdate(r.server, runner, device, queryLabel)
				if update == nil {
					continue
				}
				updates = append(updates, update)
			}

			if resp.Data.Next <= 0 || resp.Data.Next <= from {
				break
			}

			from = resp.Data.Next
		}
	}

	if len(updates) == 0 {
		return 0, nil
	}

	if err := r.sendSyncUpdates(ctx, runner, updates, runID); err != nil {
		return len(updates), err
	}

	return len(updates), nil
}

func (r *SyncRuntime) sendSyncUpdates(
	ctx context.Context,
	runner *syncSourceRunner,
	updates []map[string]interface{},
	runID string,
) error {
	chunks, err := buildSyncResultsChunks(updates, runner.config, runID)
	if err != nil {
		return err
	}
	if len(chunks) == 0 {
		return nil
	}

	statusChunks := r.buildResultsStatusChunks(chunks, syncServiceName, syncServiceType)
	if len(statusChunks) == 0 {
		return nil
	}

	_, err = r.gateway.StreamStatus(ctx, statusChunks)
	return err
}

func (r *SyncRuntime) buildResultsStatusChunks(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
) []*proto.GatewayStatusChunk {
	r.server.mu.RLock()
	agentID := r.server.config.AgentID
	partition := r.server.config.Partition
	r.server.mu.RUnlock()
	return buildResultsStatusChunksForAgent(chunks, serviceName, serviceType, agentID, partition, "")
}

func (r *syncSourceRunner) tryStart() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.inflight {
		return false
	}
	r.inflight = true
	return true
}

func (r *syncSourceRunner) finish() {
	r.mu.Lock()
	r.inflight = false
	r.mu.Unlock()
}

func syncRuntimeEnabled(cfg *ServerConfig) bool {
	if cfg == nil {
		return false
	}
	if cfg.SyncRuntimeEnabled == nil {
		return true
	}
	return *cfg.SyncRuntimeEnabled
}

func parseSyncSources(configJSON []byte) (map[string]models.SourceConfig, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var payload syncConfigPayload
	if err := json.Unmarshal(configJSON, &payload); err != nil {
		return nil, fmt.Errorf("decode sync payload: %w", err)
	}

	if len(payload.Sources) == 0 {
		return nil, nil
	}

	return payload.Sources, nil
}

func syncSourceHash(source models.SourceConfig) string {
	data, err := json.Marshal(source)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8])
}

func isSupportedSource(sourceType string) bool {
	switch strings.ToLower(strings.TrimSpace(sourceType)) {
	case armisSourceType:
		return true
	default:
		return false
	}
}

func armisPageSize(source models.SourceConfig) int {
	value := source.Credentials["page_size"]
	if value == "" {
		return defaultArmisPageSize
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return defaultArmisPageSize
	}
	return parsed
}

type armisClient struct {
	endpoint           string
	insecureSkipVerify bool
}

func newArmisClient(source models.SourceConfig) *armisClient {
	return &armisClient{
		endpoint:           strings.TrimRight(source.Endpoint, "/"),
		insecureSkipVerify: source.InsecureSkipVerify,
	}
}

func (c *armisClient) accessToken(ctx context.Context, creds map[string]string) (string, error) {
	url, err := c.resolveURL(armisAccessTokenPath)
	if err != nil {
		return "", err
	}

	payload := map[string]string{}
	if creds != nil {
		if value := creds["api_key"]; value != "" {
			payload["api_key"] = value
		}
		if value := creds["api_secret"]; value != "" {
			payload["api_secret"] = value
		}
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(body)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client().Do(req)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("%w: %s", errArmisTokenRequestFailed, resp.Status)
	}

	var token armisTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&token); err != nil {
		return "", err
	}
	if token.Data.AccessToken == "" {
		return "", errArmisTokenMissingAccessToken
	}
	return token.Data.AccessToken, nil
}

func (c *armisClient) search(ctx context.Context, token string, query string, from int, length int) (*armisSearchResponse, error) {
	endpoint, err := c.resolveURL(armisSearchPath)
	if err != nil {
		return nil, err
	}

	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}

	params := parsed.Query()
	params.Set("from", strconv.Itoa(from))
	params.Set("length", strconv.Itoa(length))
	if query != "" {
		params.Set("aql", query)
	}
	parsed.RawQuery = params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", fmt.Sprintf(armisAuthHeaderTemplate, token))
	}

	resp, err := c.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: %s", errArmisSearchFailed, resp.Status)
	}

	var result armisSearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &result, nil
}

func (c *armisClient) resolveURL(path string) (string, error) {
	base, err := url.Parse(c.endpoint)
	if err != nil {
		return "", err
	}

	ref, err := url.Parse(path)
	if err != nil {
		return "", err
	}

	return base.ResolveReference(ref).String(), nil
}

func (c *armisClient) client() *http.Client {
	transport := http.DefaultTransport
	if c.insecureSkipVerify {
		transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}
	return &http.Client{Transport: transport}
}

func filterArmisDevices(devices []armisDevice, blacklist []string) []armisDevice {
	if len(blacklist) == 0 {
		return devices
	}

	cidrs := make([]*net.IPNet, 0, len(blacklist))
	for _, raw := range blacklist {
		_, network, err := net.ParseCIDR(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		cidrs = append(cidrs, network)
	}

	if len(cidrs) == 0 {
		return devices
	}

	filtered := make([]armisDevice, 0, len(devices))
	for _, device := range devices {
		ip := net.ParseIP(device.IPAddress)
		if ip == nil {
			filtered = append(filtered, device)
			continue
		}

		blocked := false
		for _, network := range cidrs {
			if network.Contains(ip) {
				blocked = true
				break
			}
		}

		if !blocked {
			filtered = append(filtered, device)
		}
	}

	return filtered
}

func buildArmisUpdate(server *Server, runner *syncSourceRunner, device armisDevice, queryLabel string) map[string]interface{} {
	if device.IPAddress == "" {
		return nil
	}

	server.mu.RLock()
	agentID := server.config.AgentID
	partition := server.config.Partition
	server.mu.RUnlock()
	if runner.config.AgentID != "" {
		agentID = runner.config.AgentID
	}
	gatewayID := agentID
	if runner.config.GatewayID != "" {
		gatewayID = runner.config.GatewayID
	}
	if runner.config.Partition != "" {
		partition = runner.config.Partition
	}
	if partition == "" {
		partition = defaultPartition
	}

	metadata := map[string]string{
		"armis_device_id":  strconv.Itoa(device.ID),
		"integration_type": armisSourceType,
	}

	if device.Type != "" {
		metadata["armis_type"] = device.Type
	}
	if device.Category != "" {
		metadata["armis_category"] = device.Category
	}
	if device.Manufacturer != "" {
		metadata["manufacturer"] = device.Manufacturer
	}
	if device.Model != "" {
		metadata["model"] = device.Model
	}
	if device.OperatingSystem != "" {
		metadata["operating_system"] = device.OperatingSystem
	}
	if device.Boundaries != "" {
		metadata["armis_boundaries"] = device.Boundaries
	}
	if device.RiskLevel > 0 {
		metadata["armis_risk_level"] = strconv.Itoa(device.RiskLevel)
	}
	if queryLabel != "" {
		metadata["query_label"] = queryLabel
	}
	if len(device.Tags) > 0 {
		metadata["armis_tags"] = strings.Join(device.Tags, ",")
	}

	update := map[string]interface{}{
		"agent_id":   agentID,
		"gateway_id": gatewayID,
		"partition":  partition,
		"device_id":  fmt.Sprintf("%s:%s", partition, device.IPAddress),
		"ip":         device.IPAddress,
		"source":     armisSourceType,
		"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		"metadata":   metadata,
	}

	if device.MacAddress != "" {
		update["mac"] = device.MacAddress
	}
	if device.Name != "" {
		update["hostname"] = device.Name
	}

	return update
}

type syncChunkMeta struct {
	syncServiceID string
	runID         string
	totalDevices  int
}

func buildSyncResultsChunks(updates []map[string]interface{}, source models.SourceConfig, runID string) ([]*proto.ResultsChunk, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	meta := syncChunkMeta{
		syncServiceID: source.SyncServiceID,
		runID:         runID,
		totalDevices:  len(updates),
	}

	maxChunkSize, maxHosts := sweepResultsChunkLimits()
	chunkRanges, err := splitSyncUpdates(updates, maxChunkSize, maxHosts, meta)
	if err != nil {
		return nil, err
	}

	totalChunks := len(chunkRanges)
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)

	for idx, chunk := range chunkRanges {
		isFinal := idx == totalChunks-1
		applySyncMeta(chunk, meta, idx, totalChunks, isFinal)

		payload, err := json.Marshal(chunk)
		if err != nil {
			return nil, fmt.Errorf("marshal sync chunk %d: %w", idx, err)
		}

		chunks = append(chunks, &proto.ResultsChunk{
			Data:            payload,
			IsFinal:         isFinal,
			ChunkIndex:      int32(idx),
			TotalChunks:     int32(totalChunks),
			CurrentSequence: runID,
			Timestamp:       time.Now().Unix(),
		})
	}

	return chunks, nil
}

func splitSyncUpdates(
	updates []map[string]interface{},
	maxChunkSize int,
	maxHosts int,
	meta syncChunkMeta,
) ([][]map[string]interface{}, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	chunks := make([][]map[string]interface{}, 0)
	current := make([]map[string]interface{}, 0, maxHosts)
	currentSize := 2

	for _, update := range updates {
		if update == nil {
			continue
		}

		placeholder := buildSyncMeta(meta, 0, 0, false)
		update[syncMetaKey] = placeholder

		encoded, err := json.Marshal(update)
		if err != nil {
			return nil, fmt.Errorf("marshal sync update: %w", err)
		}

		entrySize := len(encoded)
		if len(current) > 0 {
			entrySize++
		}

		if (currentSize+entrySize > maxChunkSize || len(current) >= maxHosts) && len(current) > 0 {
			chunks = append(chunks, current)
			current = make([]map[string]interface{}, 0, maxHosts)
			currentSize = 2
		}

		current = append(current, update)
		currentSize += entrySize
	}

	if len(current) > 0 {
		chunks = append(chunks, current)
	}

	return chunks, nil
}

func applySyncMeta(
	updates []map[string]interface{},
	meta syncChunkMeta,
	chunkIndex int,
	totalChunks int,
	isFinal bool,
) {
	for _, update := range updates {
		if update == nil {
			continue
		}
		update[syncMetaKey] = buildSyncMeta(meta, chunkIndex, totalChunks, isFinal)
	}
}

func buildSyncMeta(meta syncChunkMeta, chunkIndex int, totalChunks int, isFinal bool) map[string]interface{} {
	return map[string]interface{}{
		"sync_service_id": meta.syncServiceID,
		"sync_run_id":     meta.runID,
		"chunk_index":     chunkIndex,
		"total_chunks":    totalChunks,
		"total_devices":   meta.totalDevices,
		"is_final":        isFinal,
	}
}
