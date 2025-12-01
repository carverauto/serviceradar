package registry

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// GraphWriter emits device/service/collector relationships into the AGE graph.
type GraphWriter interface {
	WriteGraph(ctx context.Context, updates []*models.DeviceUpdate)
}

// NewAGEGraphWriter builds an AGE-backed GraphWriter that uses cypher() against CNPG.
func NewAGEGraphWriter(executor db.QueryExecutor, log logger.Logger) GraphWriter {
	if executor == nil {
		return nil
	}
	return &ageGraphWriter{
		executor: executor,
		log:      log,
	}
}

type ageGraphWriter struct {
	executor db.QueryExecutor
	log      logger.Logger
}

type ageGraphParams struct {
	Collectors []ageGraphCollector `json:"collectors,omitempty"`
	Devices    []ageGraphDevice    `json:"devices,omitempty"`
	Services   []ageGraphService   `json:"services,omitempty"`
	ReportedBy []ageGraphEdge      `json:"reportedBy,omitempty"`
}

type ageGraphCollector struct {
	ID       string `json:"id"`
	Type     string `json:"type,omitempty"`
	IP       string `json:"ip,omitempty"`
	Hostname string `json:"hostname,omitempty"`
}

type ageGraphDevice struct {
	ID       string `json:"id"`
	IP       string `json:"ip,omitempty"`
	Hostname string `json:"hostname,omitempty"`
}

type ageGraphService struct {
	ID          string `json:"id"`
	Type        string `json:"type,omitempty"`
	IP          string `json:"ip,omitempty"`
	Hostname    string `json:"hostname,omitempty"`
	CollectorID string `json:"collector_id,omitempty"`
}

type ageGraphEdge struct {
	DeviceID    string `json:"device_id"`
	CollectorID string `json:"collector_id"`
}

func (w *ageGraphWriter) WriteGraph(ctx context.Context, updates []*models.DeviceUpdate) {
	if w == nil || w.executor == nil {
		return
	}
	params := buildAgeGraphParams(updates)
	if params == nil {
		return
	}

	payload, err := json.Marshal(params)
	if err != nil {
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to marshal params")
		}
		return
	}

	if _, err := w.executor.ExecuteQuery(ctx, ageGraphMergeQuery, payload); err != nil && w.log != nil {
		w.log.Warn().Err(err).Msg("age graph: failed to merge batch")
	}
}

func buildAgeGraphParams(updates []*models.DeviceUpdate) *ageGraphParams {
	if len(updates) == 0 {
		return nil
	}

	collectors := make(map[string]ageGraphCollector)
	devices := make(map[string]ageGraphDevice)
	services := make(map[string]ageGraphService)
	reported := make(map[string]ageGraphEdge)

	for _, update := range updates {
		if update == nil || isDeletionMetadata(update.Metadata) {
			continue
		}

		deviceID := strings.TrimSpace(update.DeviceID)
		if deviceID == "" {
			continue
		}

		hostname := trimPtr(update.Hostname)
		serviceType := deriveServiceType(update)

		// Service devices map to Collector or Service nodes, not Device nodes.
		if models.IsServiceDevice(deviceID) {
			if isCollectorService(serviceType) {
				upsertCollector(collectors, deviceID, string(serviceType), update.IP, hostname)

				// If this agent reports to a poller, ensure the poller exists for future edges.
				if serviceType == models.ServiceTypeAgent && strings.TrimSpace(update.PollerID) != "" {
					pollerID := models.GenerateServiceDeviceID(models.ServiceTypePoller, strings.TrimSpace(update.PollerID))
					upsertCollector(collectors, pollerID, string(models.ServiceTypePoller), "", "")
					addReportedEdge(reported, deviceID, pollerID)
				}
			} else {
				hostCollectorID := hostCollectorFromUpdate(update)
				upsertService(services, deviceID, string(serviceType), update.IP, hostname, hostCollectorID)
				if hostCollectorID != "" {
					// Ensure the host collector node exists so HOSTS_SERVICE can be created.
					upsertCollector(collectors, hostCollectorID, collectorTypeFromID(hostCollectorID), "", "")
				}
			}
			continue
		}

		// Non-service devices become Device nodes with provenance edges back to collectors.
		upsertDevice(devices, deviceID, update.IP, hostname)

		for _, collectorID := range collectorIDsForUpdate(update) {
			upsertCollector(collectors, collectorID.id, collectorID.kind, collectorID.ip, collectorID.hostname)
			addReportedEdge(reported, deviceID, collectorID.id)
		}
	}

	// Nothing to persist.
	if len(collectors) == 0 && len(devices) == 0 && len(services) == 0 && len(reported) == 0 {
		return nil
	}

	return &ageGraphParams{
		Collectors: mapCollectorsToSlice(collectors),
		Devices:    mapDevicesToSlice(devices),
		Services:   mapServicesToSlice(services),
		ReportedBy: mapEdgesToSlice(reported),
	}
}

type collectorRef struct {
	id       string
	kind     string
	ip       string
	hostname string
}

func collectorIDsForUpdate(update *models.DeviceUpdate) []collectorRef {
	var collectors []collectorRef

	if agentID := strings.TrimSpace(update.AgentID); agentID != "" {
		collectors = append(collectors, collectorRef{
			id:   models.GenerateServiceDeviceID(models.ServiceTypeAgent, agentID),
			kind: string(models.ServiceTypeAgent),
			ip:   "",
		})
	}

	if pollerID := strings.TrimSpace(update.PollerID); pollerID != "" {
		collectors = append(collectors, collectorRef{
			id:   models.GenerateServiceDeviceID(models.ServiceTypePoller, pollerID),
			kind: string(models.ServiceTypePoller),
			ip:   "",
		})
	}

	return collectors
}

func upsertCollector(store map[string]ageGraphCollector, id, serviceType, ip, hostname string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}

	entry, exists := store[id]
	if !exists {
		store[id] = ageGraphCollector{ID: id, Type: strings.TrimSpace(serviceType), IP: strings.TrimSpace(ip), Hostname: strings.TrimSpace(hostname)}
		return
	}

	if entry.Type == "" {
		entry.Type = strings.TrimSpace(serviceType)
	}
	if entry.IP == "" {
		entry.IP = strings.TrimSpace(ip)
	}
	if entry.Hostname == "" {
		entry.Hostname = strings.TrimSpace(hostname)
	}
	store[id] = entry
}

func upsertDevice(store map[string]ageGraphDevice, id, ip, hostname string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}

	entry, exists := store[id]
	if !exists {
		store[id] = ageGraphDevice{ID: id, IP: strings.TrimSpace(ip), Hostname: strings.TrimSpace(hostname)}
		return
	}

	if entry.IP == "" {
		entry.IP = strings.TrimSpace(ip)
	}
	if entry.Hostname == "" {
		entry.Hostname = strings.TrimSpace(hostname)
	}
	store[id] = entry
}

func upsertService(store map[string]ageGraphService, id, svcType, ip, hostname, collectorID string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}

	entry, exists := store[id]
	if !exists {
		store[id] = ageGraphService{
			ID:          id,
			Type:        strings.TrimSpace(svcType),
			IP:          strings.TrimSpace(ip),
			Hostname:    strings.TrimSpace(hostname),
			CollectorID: strings.TrimSpace(collectorID),
		}
		return
	}

	if entry.Type == "" {
		entry.Type = strings.TrimSpace(svcType)
	}
	if entry.IP == "" {
		entry.IP = strings.TrimSpace(ip)
	}
	if entry.Hostname == "" {
		entry.Hostname = strings.TrimSpace(hostname)
	}
	if entry.CollectorID == "" {
		entry.CollectorID = strings.TrimSpace(collectorID)
	}
	store[id] = entry
}

func addReportedEdge(store map[string]ageGraphEdge, deviceID, collectorID string) {
	deviceID = strings.TrimSpace(deviceID)
	collectorID = strings.TrimSpace(collectorID)
	if deviceID == "" || collectorID == "" {
		return
	}
	key := deviceID + "|" + collectorID
	if _, exists := store[key]; exists {
		return
	}
	store[key] = ageGraphEdge{
		DeviceID:    deviceID,
		CollectorID: collectorID,
	}
}

func mapCollectorsToSlice(store map[string]ageGraphCollector) []ageGraphCollector {
	out := make([]ageGraphCollector, 0, len(store))
	for _, v := range store {
		out = append(out, v)
	}
	return out
}

func mapDevicesToSlice(store map[string]ageGraphDevice) []ageGraphDevice {
	out := make([]ageGraphDevice, 0, len(store))
	for _, v := range store {
		out = append(out, v)
	}
	return out
}

func mapServicesToSlice(store map[string]ageGraphService) []ageGraphService {
	out := make([]ageGraphService, 0, len(store))
	for _, v := range store {
		out = append(out, v)
	}
	return out
}

func mapEdgesToSlice(store map[string]ageGraphEdge) []ageGraphEdge {
	out := make([]ageGraphEdge, 0, len(store))
	for _, v := range store {
		out = append(out, v)
	}
	return out
}

func deriveServiceType(update *models.DeviceUpdate) models.ServiceType {
	if update == nil {
		return ""
	}
	if update.ServiceType != nil && *update.ServiceType != "" {
		return *update.ServiceType
	}

	parts := strings.Split(strings.TrimSpace(update.DeviceID), ":")
	if len(parts) >= 2 && parts[0] == models.ServiceDevicePartition {
		return models.ServiceType(parts[1])
	}
	return ""
}

func isCollectorService(serviceType models.ServiceType) bool {
	return serviceType == models.ServiceTypeAgent || serviceType == models.ServiceTypePoller
}

func hostCollectorFromUpdate(update *models.DeviceUpdate) string {
	if update == nil {
		return ""
	}
	if agentID := strings.TrimSpace(update.AgentID); agentID != "" {
		return models.GenerateServiceDeviceID(models.ServiceTypeAgent, agentID)
	}
	if pollerID := strings.TrimSpace(update.PollerID); pollerID != "" {
		return models.GenerateServiceDeviceID(models.ServiceTypePoller, pollerID)
	}
	return ""
}

func collectorTypeFromID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 && parts[0] == models.ServiceDevicePartition {
		return parts[1]
	}
	return ""
}

func trimPtr(val *string) string {
	if val == nil {
		return ""
	}
	return strings.TrimSpace(*val)
}

const ageGraphMergeQuery = `
SELECT *
FROM cypher('serviceradar', $$
    UNWIND coalesce($collectors, []) AS c
        MERGE (col:Collector {id: c.id})
        SET col.type = coalesce(c.type, col.type),
            col.ip = coalesce(c.ip, col.ip),
            col.hostname = coalesce(c.hostname, col.hostname)

    UNWIND coalesce($devices, []) AS d
        MERGE (dev:Device {id: d.id})
        SET dev.ip = coalesce(d.ip, dev.ip),
            dev.hostname = coalesce(d.hostname, dev.hostname)

    UNWIND coalesce($services, []) AS s
        MERGE (svc:Service {id: s.id})
        SET svc.type = coalesce(s.type, svc.type),
            svc.ip = coalesce(s.ip, svc.ip),
            svc.hostname = coalesce(s.hostname, svc.hostname)
        WITH svc, s
        WHERE coalesce(s.collector_id, '') <> ''
        MERGE (col:Collector {id: s.collector_id})
        MERGE (col)-[:HOSTS_SERVICE]->(svc)

    UNWIND coalesce($reportedBy, []) AS r
        MERGE (dev:Device {id: r.device_id})
        MERGE (col:Collector {id: r.collector_id})
        MERGE (dev)-[:REPORTED_BY]->(col)
$$, $1::jsonb) AS (result agtype);
`
