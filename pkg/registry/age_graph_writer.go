package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// GraphWriter emits device/service/collector relationships into the AGE graph.
type GraphWriter interface {
	WriteGraph(ctx context.Context, updates []*models.DeviceUpdate)
	WriteInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface)
	WriteTopology(ctx context.Context, events []*models.TopologyDiscoveryEvent)
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
	executor        db.QueryExecutor
	log             logger.Logger
	successCount    uint64
	failureCount    uint64
	lastFailureWarn uint64
}

type ageGraphParams struct {
	Collectors       []ageGraphCollector     `json:"collectors,omitempty"`
	Devices          []ageGraphDevice        `json:"devices,omitempty"`
	Services         []ageGraphService       `json:"services,omitempty"`
	ReportedBy       []ageGraphEdge          `json:"reportedBy,omitempty"`
	CollectorParents []ageGraphCollectorEdge `json:"collectorParents,omitempty"`
	Targets          []ageGraphTarget        `json:"targets,omitempty"`
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

type ageGraphCollectorEdge struct {
	CollectorID       string `json:"collector_id"`
	ParentCollectorID string `json:"parent_collector_id"`
}

type ageGraphTarget struct {
	ServiceID string `json:"service_id"`
	DeviceID  string `json:"device_id"`
}

type ageGraphInterface struct {
	ID          string   `json:"id"`
	DeviceID    string   `json:"device_id"`
	Name        string   `json:"name,omitempty"`
	Descr       string   `json:"descr,omitempty"`
	Alias       string   `json:"alias,omitempty"`
	MAC         string   `json:"mac,omitempty"`
	IPAddresses []string `json:"ip_addresses,omitempty"`
	IfIndex     int32    `json:"ifindex,omitempty"`
}

type ageGraphLink struct {
	LocalDeviceID   string `json:"local_device_id"`
	LocalInterface  string `json:"local_interface_id"`
	RemoteDeviceID  string `json:"remote_device_id"`
	RemoteInterface string `json:"remote_interface_id"`
}

func (w *ageGraphWriter) WriteGraph(ctx context.Context, updates []*models.DeviceUpdate) {
	if w == nil || w.executor == nil {
		return
	}
	params := buildAgeGraphParams(updates)
	if params == nil {
		return
	}

	payloadBytes, err := json.Marshal(params)
	if err != nil {
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to marshal params")
		}
		w.recordFailure()
		return
	}

	if _, err := w.executor.ExecuteQuery(ctx, ageGraphMergeQuery, string(payloadBytes)); err != nil {
		w.recordFailure()
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to merge batch")
		}
	} else {
		w.recordSuccess()
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
	collectorParents := make(map[string]ageGraphCollectorEdge)
	targets := make(map[string]ageGraphTarget)

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
					addCollectorParent(collectorParents, deviceID, pollerID)
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

		// If this update was produced by a checker, link the checker service to the target device.
		if checkerSvc := strings.TrimSpace(update.Metadata["checker_service"]); checkerSvc != "" {
			if checkerID := checkerServiceID(checkerSvc, update.AgentID, update.PollerID); checkerID != "" {
				hostCollectorID := hostCollectorFromUpdate(update)
				upsertService(services, checkerID, string(models.ServiceTypeChecker), "", "", hostCollectorID)
				addTargetEdge(targets, checkerID, deviceID)
				if hostCollectorID != "" {
					upsertCollector(collectors, hostCollectorID, collectorTypeFromID(hostCollectorID), "", "")
				}
			}
		}
	}

	// Nothing to persist.
	if len(collectors) == 0 && len(devices) == 0 && len(services) == 0 && len(reported) == 0 && len(targets) == 0 && len(collectorParents) == 0 {
		return nil
	}

	return &ageGraphParams{
		Collectors:       mapCollectorsToSlice(collectors),
		Devices:          mapDevicesToSlice(devices),
		Services:         mapServicesToSlice(services),
		ReportedBy:       mapEdgesToSlice(reported),
		CollectorParents: mapCollectorParentsToSlice(collectorParents),
		Targets:          mapTargetsToSlice(targets),
	}
}

func (w *ageGraphWriter) WriteInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) {
	if w == nil || w.executor == nil {
		return
	}

	payload := buildInterfaceParams(interfaces)
	if len(payload) == 0 {
		return
	}

	data, err := json.Marshal(map[string]any{"interfaces": payload})
	if err != nil {
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to marshal interface payload")
		}
		w.recordFailure()
		return
	}

	if _, err := w.executor.ExecuteQuery(ctx, ageInterfaceMergeQuery, string(data)); err != nil {
		w.recordFailure()
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to merge interfaces")
		}
	} else {
		w.recordSuccess()
	}
}

func (w *ageGraphWriter) WriteTopology(ctx context.Context, events []*models.TopologyDiscoveryEvent) {
	if w == nil || w.executor == nil {
		return
	}

	payload := buildTopologyParams(events)
	if len(payload) == 0 {
		return
	}

	data, err := json.Marshal(map[string]any{"links": payload})
	if err != nil {
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to marshal topology payload")
		}
		w.recordFailure()
		return
	}

	if _, err := w.executor.ExecuteQuery(ctx, ageTopologyMergeQuery, string(data)); err != nil {
		w.recordFailure()
		if w.log != nil {
			w.log.Warn().Err(err).Msg("age graph: failed to merge topology links")
		}
	} else {
		w.recordSuccess()
	}
}

func buildInterfaceParams(interfaces []*models.DiscoveredInterface) []ageGraphInterface {
	if len(interfaces) == 0 {
		return nil
	}

	result := make([]ageGraphInterface, 0, len(interfaces))

	for _, iface := range interfaces {
		if iface == nil {
			continue
		}

		deviceID := strings.TrimSpace(iface.DeviceID)
		if deviceID == "" {
			continue
		}

		name := strings.TrimSpace(iface.IfName)
		if name == "" {
			name = fmt.Sprintf("ifindex:%d", iface.IfIndex)
		}

		ifaceID := fmt.Sprintf("%s/%s", deviceID, name)
		entry := ageGraphInterface{
			ID:          ifaceID,
			DeviceID:    deviceID,
			Name:        name,
			Descr:       strings.TrimSpace(iface.IfDescr),
			Alias:       strings.TrimSpace(iface.IfAlias),
			MAC:         strings.TrimSpace(iface.IfPhysAddress),
			IPAddresses: normalizeIPs(iface.IPAddresses),
			IfIndex:     iface.IfIndex,
		}

		result = append(result, entry)
	}

	return result
}

func buildTopologyParams(events []*models.TopologyDiscoveryEvent) []ageGraphLink {
	if len(events) == 0 {
		return nil
	}

	result := make([]ageGraphLink, 0, len(events))
	for _, ev := range events {
		if ev == nil {
			continue
		}
		localDeviceID := strings.TrimSpace(ev.LocalDeviceID)
		neighborID := strings.TrimSpace(ev.NeighborManagementAddr)
		if localDeviceID == "" || neighborID == "" {
			continue
		}

		localIfaceID := ""
		if ev.LocalIfName != "" {
			localIfaceID = fmt.Sprintf("%s/%s", localDeviceID, strings.TrimSpace(ev.LocalIfName))
		} else if ev.LocalIfIndex != 0 {
			localIfaceID = fmt.Sprintf("%s/ifindex:%d", localDeviceID, ev.LocalIfIndex)
		}

		remoteIfaceID := ""
		if ev.NeighborPortID != "" {
			remoteIfaceID = fmt.Sprintf("%s/%s", neighborID, strings.TrimSpace(ev.NeighborPortID))
		}

		result = append(result, ageGraphLink{
			LocalDeviceID:   localDeviceID,
			LocalInterface:  localIfaceID,
			RemoteDeviceID:  neighborID,
			RemoteInterface: remoteIfaceID,
		})
	}

	return result
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

func addTargetEdge(store map[string]ageGraphTarget, serviceID, deviceID string) {
	serviceID = strings.TrimSpace(serviceID)
	deviceID = strings.TrimSpace(deviceID)
	if serviceID == "" || deviceID == "" {
		return
	}
	key := serviceID + "|" + deviceID
	if _, exists := store[key]; exists {
		return
	}
	store[key] = ageGraphTarget{
		ServiceID: serviceID,
		DeviceID:  deviceID,
	}
}

func addCollectorParent(store map[string]ageGraphCollectorEdge, collectorID, parentCollectorID string) {
	collectorID = strings.TrimSpace(collectorID)
	parentCollectorID = strings.TrimSpace(parentCollectorID)
	if collectorID == "" || parentCollectorID == "" {
		return
	}
	key := collectorID + "|" + parentCollectorID
	if _, exists := store[key]; exists {
		return
	}
	store[key] = ageGraphCollectorEdge{
		CollectorID:       collectorID,
		ParentCollectorID: parentCollectorID,
	}
}

func mapCollectorsToSlice(store map[string]ageGraphCollector) []ageGraphCollector {
	out := make([]ageGraphCollector, 0, len(store))
	for _, v := range store {
		out = append(out, v)
	}
	return out
}

func mapCollectorParentsToSlice(store map[string]ageGraphCollectorEdge) []ageGraphCollectorEdge {
	out := make([]ageGraphCollectorEdge, 0, len(store))
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

func mapTargetsToSlice(store map[string]ageGraphTarget) []ageGraphTarget {
	out := make([]ageGraphTarget, 0, len(store))
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

func checkerServiceID(serviceName, agentID, pollerID string) string {
	serviceName = strings.TrimSpace(serviceName)
	if serviceName == "" {
		return ""
	}

	if agentID := strings.TrimSpace(agentID); agentID != "" {
		return models.GenerateServiceDeviceID(models.ServiceTypeChecker, fmt.Sprintf("%s@%s", serviceName, agentID))
	}

	if pollerID := strings.TrimSpace(pollerID); pollerID != "" {
		return models.GenerateServiceDeviceID(models.ServiceTypeChecker, fmt.Sprintf("%s@%s", serviceName, pollerID))
	}

	return ""
}

func trimPtr(val *string) string {
	if val == nil {
		return ""
	}
	return strings.TrimSpace(*val)
}

func normalizeIPs(ips []string) []string {
	if len(ips) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(ips))
	result := make([]string, 0, len(ips))
	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		result = append(result, ip)
	}
	return result
}

func (w *ageGraphWriter) recordSuccess() {
	if w == nil {
		return
	}
	atomic.AddUint64(&w.successCount, 1)
	recordAgeGraphSuccess()
}

func (w *ageGraphWriter) recordFailure() {
	if w == nil {
		return
	}
	total := atomic.AddUint64(&w.failureCount, 1)
	recordAgeGraphFailure()
	if w.log != nil {
		// Warn every 10th failure to avoid log spam.
		if total == 1 || total%10 == 0 {
			successes := atomic.LoadUint64(&w.successCount)
			w.log.Warn().
				Uint64("age_graph_failures", total).
				Uint64("age_graph_successes", successes).
				Msg("age graph: write failures observed")
		}
	}
}

const ageGraphMergeQuery = `
SELECT *
FROM ag_catalog.cypher(
         'serviceradar',
         $agefmt$
             WITH coalesce($collectors, []) AS collectors,
                  coalesce($devices, []) AS devices,
                  coalesce($services, []) AS services,
                  coalesce($reportedBy, []) AS reportedBy,
                  coalesce($collectorParents, []) AS collectorParents,
                  coalesce($targets, []) AS targets

             UNWIND collectors AS c
                 MERGE (col:Collector {id: c.id})
                 SET col.type = coalesce(c.type, col.type),
                     col.ip = coalesce(c.ip, col.ip),
                     col.hostname = coalesce(c.hostname, col.hostname)
                 WITH collectors, devices, services, reportedBy, collectorParents, targets

             UNWIND devices AS d
                 MERGE (dev:Device {id: d.id})
                 SET dev.ip = coalesce(d.ip, dev.ip),
                     dev.hostname = coalesce(d.hostname, dev.hostname)
                 WITH collectors, devices, services, reportedBy, collectorParents, targets

             UNWIND services AS s
                 MERGE (svc:Service {id: s.id})
                 SET svc.type = coalesce(s.type, svc.type),
                     svc.ip = coalesce(s.ip, svc.ip),
                     svc.hostname = coalesce(s.hostname, svc.hostname)
                 WITH svc, s, collectors, devices, services, reportedBy, collectorParents, targets
                 WHERE coalesce(s.collector_id, '') <> ''
                 MERGE (col:Collector {id: s.collector_id})
                 MERGE (col)-[:HOSTS_SERVICE]->(svc)
                 WITH col, svc, s, collectors, devices, services, reportedBy, collectorParents, targets,
                      CASE WHEN coalesce(s.type, '') = 'checker' THEN [1] ELSE [] END AS run_checker
                 UNWIND run_checker AS _
                     MERGE (col)-[:RUNS_CHECKER]->(svc)
                 WITH collectors, devices, services, reportedBy, collectorParents, targets

             UNWIND reportedBy AS r
                 WITH r, collectorParents, targets, reportedBy
                 WHERE NOT r.device_id STARTS WITH 'serviceradar:'
                 MERGE (dev:Device {id: r.device_id})
                 MERGE (col:Collector {id: r.collector_id})
                 MERGE (dev)-[:REPORTED_BY]->(col)
                 WITH collectorParents, targets, reportedBy

             UNWIND reportedBy AS r
                 WITH r, collectorParents, targets, reportedBy
                 WHERE r.device_id STARTS WITH 'serviceradar:'
                 MERGE (child:Collector {id: r.device_id})
                 MERGE (parent:Collector {id: r.collector_id})
                 MERGE (child)-[:REPORTED_BY]->(parent)
                 WITH collectorParents, targets

             UNWIND collectorParents AS cp
                 MERGE (child:Collector {id: cp.collector_id})
                 MERGE (parent:Collector {id: cp.parent_collector_id})
                 MERGE (child)-[:REPORTED_BY]->(parent)
                 WITH targets

             UNWIND targets AS t
                 MERGE (svc:Service {id: t.service_id})
                 MERGE (dev:Device {id: t.device_id})
                 MERGE (svc)-[:TARGETS]->(dev)
         $agefmt$,
         $1
     ) AS (result agtype);
`

const ageInterfaceMergeQuery = `
SELECT *
FROM ag_catalog.cypher(
         'serviceradar',
         $agefmt$
             WITH coalesce($interfaces, []) AS interfaces
             UNWIND interfaces AS i
                 MERGE (d:Device {id: i.device_id})
                 MERGE (iface:Interface {id: i.id})
                 SET iface.name = coalesce(i.name, iface.name),
                     iface.descr = coalesce(i.descr, iface.descr),
                     iface.alias = coalesce(i.alias, iface.alias),
                     iface.mac = coalesce(i.mac, iface.mac),
                     iface.ip_addresses = coalesce(i.ip_addresses, iface.ip_addresses),
                     iface.ifindex = coalesce(i.ifindex, iface.ifindex)
                 MERGE (d)-[:HAS_INTERFACE]->(iface)
         $agefmt$,
         $1
     ) AS (result agtype);
`

const ageTopologyMergeQuery = `
SELECT *
FROM ag_catalog.cypher(
         'serviceradar',
         $agefmt$
             WITH coalesce($links, []) AS links
             UNWIND links AS l
                 MATCH (src:Device {id: l.local_device_id})
                 MATCH (dst:Device {id: l.remote_device_id})
                 WITH l, src, dst,
                      coalesce(l.local_interface_id, src.id) AS local_iface_id,
                      coalesce(l.remote_interface_id, dst.id) AS remote_iface_id
                 MERGE (srcIface:Interface {id: local_iface_id}) // fallback to device if iface missing
                 MERGE (dstIface:Interface {id: remote_iface_id})
                 MERGE (src)-[:HAS_INTERFACE]->(srcIface)
                 MERGE (dst)-[:HAS_INTERFACE]->(dstIface)
                 MERGE (srcIface)-[:CONNECTS_TO]->(dstIface)
         $agefmt$,
         $1
     ) AS (result agtype);
`
