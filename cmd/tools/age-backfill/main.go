package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

const (
	defaultSearchPath   = `ag_catalog,"$user",public`
	deviceBatchSize     = 500
	interfaceBatchSize  = 500
	topologyBatchSize   = 500
	discoverySource     = models.DiscoverySourceServiceRadar
	unifiedDevicesQuery = `
SELECT
    device_id,
    ip,
    agent_id,
    poller_id,
    hostname,
    service_type,
    metadata
FROM unified_devices
WHERE (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'`
	interfacesQuery = `
SELECT DISTINCT ON (device_id, COALESCE(NULLIF(if_name, ''), 'ifindex:' || if_index::text))
    device_id,
    agent_id,
    poller_id,
    device_ip,
    if_index,
    if_name,
    if_descr,
    if_alias,
    if_phys_address,
    ip_addresses,
    metadata
FROM discovered_interfaces
WHERE device_id IS NOT NULL AND device_id <> ''
ORDER BY device_id, COALESCE(NULLIF(if_name, ''), 'ifindex:' || if_index::text), timestamp DESC`
	topologyQuery = `
SELECT DISTINCT ON (local_device_id, neighbor_management_addr, neighbor_port_id)
    local_device_id,
    agent_id,
    poller_id,
    local_if_index,
    local_if_name,
    protocol_type,
    neighbor_management_addr,
    neighbor_port_id,
    neighbor_chassis_id,
    neighbor_port_descr,
    neighbor_system_name,
    neighbor_bgp_router_id,
    neighbor_ip_address,
    neighbor_as,
    bgp_session_state,
    metadata
FROM topology_discovery_events
WHERE local_device_id IS NOT NULL AND local_device_id <> ''
ORDER BY local_device_id, neighbor_management_addr, neighbor_port_id, timestamp DESC`
)

var (
	errMissingCNPGHost      = errors.New("cnpg host is required")
	errMissingCNPGDatabase  = errors.New("cnpg database is required")
	errMissingCNPGPool      = errors.New("cnpg pool not configured")
	errMissingGraphExecutor = errors.New("age graph writer not initialized")
)

type config struct {
	host         string
	port         int
	database     string
	username     string
	password     string
	passwordFile string
	sslMode      string
	appName      string
}

func main() {
	cfg := parseFlags()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, cfg)
	cancel()

	if err != nil {
		log.Printf("age-backfill: %v", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg *config) error {
	if cfg.host == "" {
		return errMissingCNPGHost
	}
	if cfg.database == "" {
		return errMissingCNPGDatabase
	}

	if cfg.password == "" && cfg.passwordFile != "" {
		bytes, err := os.ReadFile(cfg.passwordFile)
		if err != nil {
			return fmt.Errorf("read password file: %w", err)
		}
		cfg.password = strings.TrimSpace(string(bytes))
	}

	logCfg := &logger.Config{
		Level:  "info",
		Output: "stdout",
	}
	appLogger, err := lifecycle.CreateComponentLogger(ctx, "age-backfill", logCfg)
	if err != nil {
		return fmt.Errorf("initialize logger: %w", err)
	}

	cnpg := &models.CNPGDatabase{
		Host:            cfg.host,
		Port:            cfg.port,
		Database:        cfg.database,
		Username:        cfg.username,
		Password:        cfg.password,
		SSLMode:         cfg.sslMode,
		ApplicationName: cfg.appName,
		ExtraRuntimeParams: map[string]string{
			"search_path": defaultSearchPath,
		},
	}

	// Ensure age-backfill runs graph writes synchronously so the process
	// does not exit before the queue drains. Core defaults to async.
	if _, ok := os.LookupEnv("AGE_GRAPH_ASYNC"); !ok {
		_ = os.Setenv("AGE_GRAPH_ASYNC", "false")
	}

	pool, err := db.NewCNPGPool(ctx, cnpg, appLogger)
	if err != nil {
		return fmt.Errorf("dial cnpg: %w", err)
	}
	if pool == nil {
		return errMissingCNPGPool
	}
	defer pool.Close()

	executor := &poolExecutor{pool: pool}
	graphWriter := registry.NewAGEGraphWriter(executor, appLogger)
	if graphWriter == nil {
		return errMissingGraphExecutor
	}

	now := time.Now().UTC()

	deviceUpdates, err := loadDeviceUpdates(ctx, pool, now)
	if err != nil {
		return fmt.Errorf("load unified_devices: %w", err)
	}
	writeBatches(ctx, graphWriter, deviceUpdates, deviceBatchSize, appLogger)

	interfaces, err := loadInterfaces(ctx, pool)
	if err != nil {
		return fmt.Errorf("load discovered_interfaces: %w", err)
	}
	writeInterfaceBatches(ctx, graphWriter, interfaces, interfaceBatchSize, appLogger)

	topology, err := loadTopology(ctx, pool)
	if err != nil {
		return fmt.Errorf("load topology_discovery_events: %w", err)
	}
	writeTopologyBatches(ctx, graphWriter, topology, topologyBatchSize, appLogger)

	appLogger.Info().
		Int("devices", len(deviceUpdates)).
		Int("interfaces", len(interfaces)).
		Int("topology_links", len(topology)).
		Msg("age backfill completed")

	return nil
}

func parseFlags() *config {
	cfg := &config{}
	flag.StringVar(&cfg.host, "host", envOr("CNPG_HOST", "localhost"), "CNPG host")
	flag.IntVar(&cfg.port, "port", envOrInt("CNPG_PORT", 5432), "CNPG port")
	flag.StringVar(&cfg.database, "database", envOr("CNPG_DATABASE", "serviceradar"), "CNPG database")
	flag.StringVar(&cfg.username, "username", envOr("CNPG_USERNAME", "serviceradar"), "CNPG username")
	flag.StringVar(&cfg.password, "password", envOr("CNPG_PASSWORD", ""), "CNPG password")
	flag.StringVar(&cfg.passwordFile, "password-file", envOr("CNPG_PASSWORD_FILE", ""), "Path to CNPG password file")
	flag.StringVar(&cfg.sslMode, "sslmode", envOr("CNPG_SSL_MODE", "disable"), "CNPG SSL mode")
	flag.StringVar(&cfg.appName, "app-name", envOr("CNPG_APP_NAME", "age-backfill"), "CNPG application_name")
	flag.Parse()
	return cfg
}

func envOr(key, fallback string) string {
	if val := strings.TrimSpace(os.Getenv(key)); val != "" {
		return val
	}
	return fallback
}

func envOrInt(key string, fallback int) int {
	if val := strings.TrimSpace(os.Getenv(key)); val != "" {
		if parsed, err := strconv.Atoi(val); err == nil {
			return parsed
		}
	}
	return fallback
}

func loadDeviceUpdates(ctx context.Context, pool *pgxpool.Pool, ts time.Time) ([]*models.DeviceUpdate, error) {
	rows, err := pool.Query(ctx, unifiedDevicesQuery)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var updates []*models.DeviceUpdate

	for rows.Next() {
		var (
			deviceID    string
			ip          sql.NullString
			agentID     sql.NullString
			pollerID    sql.NullString
			hostname    sql.NullString
			serviceType sql.NullString
			metadataRaw []byte
		)

		if err := rows.Scan(&deviceID, &ip, &agentID, &pollerID, &hostname, &serviceType, &metadataRaw); err != nil {
			return nil, err
		}

		md := map[string]string{}
		if len(metadataRaw) > 0 {
			var tmp map[string]interface{}
			if err := json.Unmarshal(metadataRaw, &tmp); err == nil {
				for k, v := range tmp {
					if s, ok := v.(string); ok {
						md[k] = s
					}
				}
			}
		}

		update := &models.DeviceUpdate{
			DeviceID:    strings.TrimSpace(deviceID),
			IP:          strings.TrimSpace(ip.String),
			AgentID:     strings.TrimSpace(agentID.String),
			PollerID:    strings.TrimSpace(pollerID.String),
			Timestamp:   ts,
			Metadata:    md,
			IsAvailable: true,
			Source:      discoverySource,
			Confidence:  models.GetSourceConfidence(discoverySource),
		}

		if hostname.Valid {
			hostCopy := strings.TrimSpace(hostname.String)
			update.Hostname = &hostCopy
		}

		if serviceType.Valid && strings.TrimSpace(serviceType.String) != "" {
			st := models.ServiceType(strings.TrimSpace(serviceType.String))
			update.ServiceType = &st
		}

		if update.DeviceID != "" {
			updates = append(updates, update)
		}
	}

	return updates, rows.Err()
}

func loadInterfaces(ctx context.Context, pool *pgxpool.Pool) ([]*models.DiscoveredInterface, error) {
	rows, err := pool.Query(ctx, interfacesQuery)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var interfaces []*models.DiscoveredInterface

	for rows.Next() {
		var (
			deviceID      sql.NullString
			agentID       sql.NullString
			pollerID      sql.NullString
			deviceIP      sql.NullString
			ifIndex       sql.NullInt32
			ifName        sql.NullString
			ifDescr       sql.NullString
			ifAlias       sql.NullString
			ifPhysAddress sql.NullString
			ipAddresses   []string
			metadataRaw   []byte
		)

		if err := rows.Scan(
			&deviceID,
			&agentID,
			&pollerID,
			&deviceIP,
			&ifIndex,
			&ifName,
			&ifDescr,
			&ifAlias,
			&ifPhysAddress,
			&ipAddresses,
			&metadataRaw,
		); err != nil {
			return nil, err
		}

		md := json.RawMessage(metadataRaw)

		iface := &models.DiscoveredInterface{
			AgentID:       strings.TrimSpace(agentID.String),
			PollerID:      strings.TrimSpace(pollerID.String),
			DeviceIP:      strings.TrimSpace(deviceIP.String),
			DeviceID:      strings.TrimSpace(deviceID.String),
			IfIndex:       ifIndex.Int32,
			IfName:        strings.TrimSpace(ifName.String),
			IfDescr:       strings.TrimSpace(ifDescr.String),
			IfAlias:       strings.TrimSpace(ifAlias.String),
			IfPhysAddress: strings.TrimSpace(ifPhysAddress.String),
			IPAddresses:   ipAddresses,
			Metadata:      md,
		}

		if iface.DeviceID != "" {
			interfaces = append(interfaces, iface)
		}
	}

	return interfaces, rows.Err()
}

func loadTopology(ctx context.Context, pool *pgxpool.Pool) ([]*models.TopologyDiscoveryEvent, error) {
	rows, err := pool.Query(ctx, topologyQuery)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []*models.TopologyDiscoveryEvent

	for rows.Next() {
		var (
			localDeviceID       sql.NullString
			agentID             sql.NullString
			pollerID            sql.NullString
			localIfIndex        sql.NullInt32
			localIfName         sql.NullString
			protocolType        sql.NullString
			neighborManagement  sql.NullString
			neighborPortID      sql.NullString
			neighborChassisID   sql.NullString
			neighborPortDescr   sql.NullString
			neighborSystemName  sql.NullString
			neighborBGPRouterID sql.NullString
			neighborIPAddress   sql.NullString
			neighborAS          sql.NullInt64
			bgpSessionState     sql.NullString
			metadataRaw         []byte
		)

		if err := rows.Scan(
			&localDeviceID,
			&agentID,
			&pollerID,
			&localIfIndex,
			&localIfName,
			&protocolType,
			&neighborManagement,
			&neighborPortID,
			&neighborChassisID,
			&neighborPortDescr,
			&neighborSystemName,
			&neighborBGPRouterID,
			&neighborIPAddress,
			&neighborAS,
			&bgpSessionState,
			&metadataRaw,
		); err != nil {
			return nil, err
		}

		event := &models.TopologyDiscoveryEvent{
			AgentID:                strings.TrimSpace(agentID.String),
			PollerID:               strings.TrimSpace(pollerID.String),
			LocalDeviceID:          strings.TrimSpace(localDeviceID.String),
			LocalIfIndex:           localIfIndex.Int32,
			LocalIfName:            strings.TrimSpace(localIfName.String),
			ProtocolType:           strings.TrimSpace(protocolType.String),
			NeighborManagementAddr: strings.TrimSpace(neighborManagement.String),
			NeighborPortID:         strings.TrimSpace(neighborPortID.String),
			NeighborChassisID:      strings.TrimSpace(neighborChassisID.String),
			NeighborPortDescr:      strings.TrimSpace(neighborPortDescr.String),
			NeighborSystemName:     strings.TrimSpace(neighborSystemName.String),
			NeighborBGPRouterID:    strings.TrimSpace(neighborBGPRouterID.String),
			NeighborIPAddress:      strings.TrimSpace(neighborIPAddress.String),
			NeighborAS:             uint32(neighborAS.Int64),
			BGPSessionState:        strings.TrimSpace(bgpSessionState.String),
			Metadata:               json.RawMessage(metadataRaw),
		}

		if event.LocalDeviceID != "" && event.NeighborManagementAddr != "" {
			events = append(events, event)
		}
	}

	return events, rows.Err()
}

func writeBatches(ctx context.Context, writer registry.GraphWriter, updates []*models.DeviceUpdate, batchSize int, log logger.Logger) {
	for start := 0; start < len(updates); start += batchSize {
		end := start + batchSize
		if end > len(updates) {
			end = len(updates)
		}
		writer.WriteGraph(ctx, updates[start:end])
	}
	log.Info().Int("count", len(updates)).Msg("age backfill: device batches written")
}

func writeInterfaceBatches(ctx context.Context, writer registry.GraphWriter, interfaces []*models.DiscoveredInterface, batchSize int, log logger.Logger) {
	for start := 0; start < len(interfaces); start += batchSize {
		end := start + batchSize
		if end > len(interfaces) {
			end = len(interfaces)
		}
		writer.WriteInterfaces(ctx, interfaces[start:end])
	}
	log.Info().Int("count", len(interfaces)).Msg("age backfill: interfaces written")
}

func writeTopologyBatches(ctx context.Context, writer registry.GraphWriter, events []*models.TopologyDiscoveryEvent, batchSize int, log logger.Logger) {
	for start := 0; start < len(events); start += batchSize {
		end := start + batchSize
		if end > len(events) {
			end = len(events)
		}
		writer.WriteTopology(ctx, events[start:end])
	}
	log.Info().Int("count", len(events)).Msg("age backfill: topology links written")
}

type poolExecutor struct {
	pool *pgxpool.Pool
}

func (p *poolExecutor) ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error) {
	rows, err := p.pool.Query(ctx, query, params...)
	if err != nil {
		return nil, fmt.Errorf("execute query: %w", err)
	}
	defer rows.Close()

	fieldDescriptions := rows.FieldDescriptions()
	var results []map[string]interface{}

	for rows.Next() {
		values, err := rows.Values()
		if err != nil {
			return nil, fmt.Errorf("read row values: %w", err)
		}

		row := make(map[string]interface{}, len(fieldDescriptions))
		for idx, fd := range fieldDescriptions {
			row[fd.Name] = values[idx]
		}

		results = append(results, row)
	}

	return results, rows.Err()
}
