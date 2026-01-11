package db

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const insertDiscoveredInterfaceSQL = `
INSERT INTO discovered_interfaces (
    timestamp,
    agent_id,
    gateway_id,
    device_ip,
    device_id,
    if_index,
    if_name,
    if_descr,
    if_alias,
    if_speed,
    if_phys_address,
    ip_addresses,
    if_admin_status,
    if_oper_status,
    metadata
) VALUES (
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15
)`

const insertTopologyEventSQL = `
INSERT INTO topology_discovery_events (
    timestamp,
    agent_id,
    gateway_id,
    local_device_ip,
    local_device_id,
    local_if_index,
    local_if_name,
    protocol_type,
    neighbor_chassis_id,
    neighbor_port_id,
    neighbor_port_descr,
    neighbor_system_name,
    neighbor_management_addr,
    neighbor_bgp_router_id,
    neighbor_ip_address,
    neighbor_as,
    bgp_session_state,
    metadata
) VALUES (
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18
)`

func (db *DB) cnpgInsertDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error {
	if len(interfaces) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, iface := range interfaces {
		args, err := buildDiscoveredInterfaceArgs(iface)
		if err != nil {
			db.logger.Warn().Err(err).
				Str("device_ip", safeInterfaceIP(iface)).
				Msg("skipping discovered interface")
			continue
		}
		batch.Queue(insertDiscoveredInterfaceSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "discovered interfaces")
}

func (db *DB) cnpgInsertTopologyEvents(ctx context.Context, events []*models.TopologyDiscoveryEvent) error {
	if len(events) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, event := range events {
		args, err := buildTopologyEventArgs(event)
		if err != nil {
			db.logger.Warn().Err(err).
				Str("local_device_ip", safeTopologyIP(event)).
				Msg("skipping topology event")
			continue
		}
		batch.Queue(insertTopologyEventSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "topology discovery event")
}

func buildDiscoveredInterfaceArgs(iface *models.DiscoveredInterface) ([]interface{}, error) {
	if iface == nil {
		return nil, ErrDiscoveredInterfaceNil
	}

	agentID := strings.TrimSpace(iface.AgentID)
	gatewayID := strings.TrimSpace(iface.GatewayID)
	deviceIP := strings.TrimSpace(iface.DeviceIP)

	if agentID == "" || gatewayID == "" || deviceIP == "" {
		return nil, ErrDiscoveredIdentifiersMissing
	}

	metadata := normalizeRawJSON(iface.Metadata)

	return []interface{}{
		sanitizeTimestamp(iface.Timestamp),
		agentID,
		gatewayID,
		deviceIP,
		strings.TrimSpace(iface.DeviceID),
		iface.IfIndex,
		strings.TrimSpace(iface.IfName),
		strings.TrimSpace(iface.IfDescr),
		strings.TrimSpace(iface.IfAlias),
		iface.IfSpeed,
		strings.TrimSpace(iface.IfPhysAddress),
		iface.IPAddresses,
		iface.IfAdminStatus,
		iface.IfOperStatus,
		metadata,
	}, nil
}

func buildTopologyEventArgs(event *models.TopologyDiscoveryEvent) ([]interface{}, error) {
	if event == nil {
		return nil, ErrTopologyEventNil
	}

	agentID := strings.TrimSpace(event.AgentID)
	gatewayID := strings.TrimSpace(event.GatewayID)
	deviceIP := strings.TrimSpace(event.LocalDeviceIP)
	protocol := strings.TrimSpace(event.ProtocolType)

	if agentID == "" || gatewayID == "" || deviceIP == "" || protocol == "" {
		return nil, ErrTopologyIdentifiersMissing
	}

	metadata := normalizeRawJSON(event.Metadata)

	return []interface{}{
		sanitizeTimestamp(event.Timestamp),
		agentID,
		gatewayID,
		deviceIP,
		strings.TrimSpace(event.LocalDeviceID),
		event.LocalIfIndex,
		strings.TrimSpace(event.LocalIfName),
		protocol,
		strings.TrimSpace(event.NeighborChassisID),
		strings.TrimSpace(event.NeighborPortID),
		strings.TrimSpace(event.NeighborPortDescr),
		strings.TrimSpace(event.NeighborSystemName),
		strings.TrimSpace(event.NeighborManagementAddr),
		strings.TrimSpace(event.NeighborBGPRouterID),
		strings.TrimSpace(event.NeighborIPAddress),
		event.NeighborAS,
		strings.TrimSpace(event.BGPSessionState),
		metadata,
	}, nil
}

func safeInterfaceIP(iface *models.DiscoveredInterface) string {
	if iface == nil {
		return ""
	}
	return strings.TrimSpace(iface.DeviceIP)
}

func safeTopologyIP(event *models.TopologyDiscoveryEvent) string {
	if event == nil {
		return ""
	}
	return strings.TrimSpace(event.LocalDeviceIP)
}
