package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const insertSweepHostStatesSQL = `
INSERT INTO sweep_host_states (
	host_ip,
	poller_id,
	agent_id,
	partition,
	network_cidr,
	hostname,
	mac,
	icmp_available,
	icmp_response_time_ns,
	icmp_packet_loss,
	tcp_ports_scanned,
	tcp_ports_open,
	port_scan_results,
	last_sweep_time,
	first_seen,
	metadata
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
)`

func (db *DB) cnpgInsertSweepHostStates(ctx context.Context, states []*models.SweepHostState) error {
	if len(states) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, state := range states {
		args, err := buildSweepHostStateArgs(state)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("host_ip", safeString(state, func(s *models.SweepHostState) string { return s.HostIP })).
				Msg("skipping sweep host state for CNPG")
			continue
		}

		batch.Queue(insertSweepHostStatesSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "sweep host states")
}

func buildSweepHostStateArgs(state *models.SweepHostState) ([]interface{}, error) {
	if state == nil {
		return nil, fmt.Errorf("sweep host state is nil")
	}

	if strings.TrimSpace(state.HostIP) == "" {
		return nil, fmt.Errorf("host ip is required")
	}
	if strings.TrimSpace(state.PollerID) == "" {
		return nil, fmt.Errorf("poller id is required")
	}
	if strings.TrimSpace(state.AgentID) == "" {
		return nil, fmt.Errorf("agent id is required")
	}
	if strings.TrimSpace(state.Partition) == "" {
		state.Partition = "default"
	}

	portsScanned, err := marshalJSONField(state.TCPPortsScanned)
	if err != nil {
		return nil, fmt.Errorf("tcp_ports_scanned: %w", err)
	}

	portsOpen, err := marshalJSONField(state.TCPPortsOpen)
	if err != nil {
		return nil, fmt.Errorf("tcp_ports_open: %w", err)
	}

	portResults, err := marshalJSONField(state.PortScanResults)
	if err != nil {
		return nil, fmt.Errorf("port_scan_results: %w", err)
	}

	metadata, err := marshalJSONField(state.Metadata)
	if err != nil {
		return nil, fmt.Errorf("metadata: %w", err)
	}

	lastSweep := sanitizeTimestamp(state.LastSweepTime)
	firstSeen := sanitizeTimestamp(state.FirstSeen)

	return []interface{}{
		state.HostIP,
		state.PollerID,
		state.AgentID,
		state.Partition,
		toNullableString(state.NetworkCIDR),
		toNullableString(state.Hostname),
		toNullableString(state.MAC),
		state.ICMPAvailable,
		toNullableInt64(state.ICMPResponseTime),
		toNullableFloat64(state.ICMPPacketLoss),
		portsScanned,
		portsOpen,
		portResults,
		lastSweep,
		firstSeen,
		metadata,
	}, nil
}

func marshalJSONField(value interface{}) (interface{}, error) {
	switch v := value.(type) {
	case nil:
		return nil, nil
	case []int:
		if len(v) == 0 {
			return nil, nil
		}
	case []models.PortResult:
		if len(v) == 0 {
			return nil, nil
		}
	case map[string]string:
		if len(v) == 0 {
			return nil, nil
		}
	}

	bytes, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}

	return json.RawMessage(bytes), nil
}

func toNullableInt64(value *int64) interface{} {
	if value == nil {
		return nil
	}

	return *value
}

func toNullableFloat64(value *float64) interface{} {
	if value == nil {
		return nil
	}

	return *value
}

func safeString(state *models.SweepHostState, getter func(*models.SweepHostState) string) string {
	if state == nil {
		return ""
	}

	return getter(state)
}

func (db *DB) cnpgGetSweepHostStates(ctx context.Context, pollerID string, limit int) ([]*models.SweepHostState, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT 
			host_ip,
			poller_id,
			agent_id,
			partition,
			network_cidr,
			hostname,
			mac,
			icmp_available,
			icmp_response_time_ns,
			icmp_packet_loss,
			tcp_ports_scanned,
			tcp_ports_open,
			port_scan_results,
			last_sweep_time,
			first_seen,
			metadata
		FROM sweep_host_states
		WHERE poller_id = $1
		ORDER BY last_sweep_time DESC
		LIMIT $2`, pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("cnpg sweep host states: %w", err)
	}
	defer rows.Close()

	var states []*models.SweepHostState

	for rows.Next() {
		var (
			state        models.SweepHostState
			networkCIDR  sql.NullString
			hostname     sql.NullString
			mac          sql.NullString
			icmpRespTime sql.NullInt64
			icmpLoss     sql.NullFloat64
			portsScanned []byte
			portsOpen    []byte
			portResults  []byte
			firstSeen    sql.NullTime
			metadata     []byte
		)

		if err := rows.Scan(
			&state.HostIP,
			&state.PollerID,
			&state.AgentID,
			&state.Partition,
			&networkCIDR,
			&hostname,
			&mac,
			&state.ICMPAvailable,
			&icmpRespTime,
			&icmpLoss,
			&portsScanned,
			&portsOpen,
			&portResults,
			&state.LastSweepTime,
			&firstSeen,
			&metadata,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan sweep host state: %w", err)
		}

		state.NetworkCIDR = stringPtrFromNull(networkCIDR)
		state.Hostname = stringPtrFromNull(hostname)
		state.MAC = stringPtrFromNull(mac)
		state.ICMPResponseTime = int64PtrFromNull(icmpRespTime)
		state.ICMPPacketLoss = float64PtrFromNull(icmpLoss)

		if decoded, err := decodeJSONIntSlice(portsScanned); err == nil {
			state.TCPPortsScanned = decoded
		} else if len(portsScanned) > 0 {
			db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to decode tcp_ports_scanned")
		}

		if decoded, err := decodeJSONIntSlice(portsOpen); err == nil {
			state.TCPPortsOpen = decoded
		} else if len(portsOpen) > 0 {
			db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to decode tcp_ports_open")
		}

		if decoded, err := decodeJSONPortResults(portResults); err == nil {
			state.PortScanResults = decoded
		} else if len(portResults) > 0 {
			db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to decode port_scan_results")
		}

		if firstSeen.Valid {
			state.FirstSeen = firstSeen.Time
		}

		if decoded, err := decodeJSONMetadata(metadata); err == nil {
			state.Metadata = decoded
		} else if len(metadata) > 0 {
			db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to decode sweep metadata")
		}

		states = append(states, &state)
	}

	return states, rows.Err()
}

func stringPtrFromNull(ns sql.NullString) *string {
	if ns.Valid {
		value := ns.String
		return &value
	}
	return nil
}

func int64PtrFromNull(n sql.NullInt64) *int64 {
	if n.Valid {
		value := n.Int64
		return &value
	}
	return nil
}

func float64PtrFromNull(n sql.NullFloat64) *float64 {
	if n.Valid {
		value := n.Float64
		return &value
	}
	return nil
}

func decodeJSONIntSlice(raw []byte) ([]int, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var values []int
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, err
	}
	return values, nil
}

func decodeJSONPortResults(raw []byte) ([]models.PortResult, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var results []models.PortResult
	if err := json.Unmarshal(raw, &results); err != nil {
		return nil, err
	}
	return results, nil
}

func decodeJSONMetadata(raw []byte) (map[string]string, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var metadata map[string]string
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return nil, err
	}
	return metadata, nil
}
