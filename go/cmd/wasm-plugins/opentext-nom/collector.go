package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Collector struct {
	HTTP  HTTPDoer
	Now   func() time.Time
	Sleep sleepFunc
}

func NewCollector(httpClient HTTPDoer) *Collector {
	return &Collector{
		HTTP:  httpClient,
		Now:   time.Now,
		Sleep: sleepWithContext,
	}
}

func (c *Collector) Collect(ctx context.Context, cfg Config) (Snapshot, error) {
	if c == nil || c.HTTP == nil {
		return Snapshot{}, runError("opentext_nom_transport_unavailable")
	}
	if err := cfg.Validate(); err != nil {
		return Snapshot{}, runError("opentext_nom_config_invalid")
	}

	devices := make(map[string]InventoryDevice)
	receivedRows := 0
	invalidRows := 0
	duplicateRows := 0
	pages := 0

	for _, query := range cfg.Queries {
		startID := int64(0)
		for {
			rows, status, err := c.fetchPage(ctx, cfg, query, startID)
			if err != nil {
				return Snapshot{}, err
			}
			if status == http.StatusUnauthorized {
				return Snapshot{}, runError("opentext_nom_auth_failed")
			}
			if status == http.StatusForbidden {
				return Snapshot{}, runError("opentext_nom_forbidden")
			}
			if status != http.StatusOK {
				return Snapshot{}, runError("opentext_nom_api_unavailable")
			}

			pages++
			receivedRows += len(rows)
			if receivedRows > cfg.MaxRows {
				return Snapshot{}, runError("opentext_nom_row_limit_exceeded")
			}

			maxID := startID - 1
			for _, raw := range rows {
				row, ok := normalizeDeviceRow(raw)
				if !ok || row.DeviceID == "" {
					return Snapshot{}, runError("opentext_nom_device_invalid")
				}
				id, ok := parseDeviceID(row.DeviceID)
				if !ok {
					return Snapshot{}, runError("opentext_nom_device_invalid")
				}
				if id > maxID {
					maxID = id
				}

				device := inventoryDevice(cfg.InstanceID, row)
				if previous, exists := devices[row.DeviceID]; exists {
					if !sameInventoryDevice(previous, device) {
						return Snapshot{}, runError("opentext_nom_duplicate_conflict")
					}
					duplicateRows++
					continue
				}
				devices[row.DeviceID] = device
			}

			if len(rows) < cfg.PageSize {
				break
			}
			if maxID < startID {
				return Snapshot{}, runError("opentext_nom_pagination_invalid")
			}
			nextStartID := maxID + 1
			if nextStartID <= startID {
				return Snapshot{}, runError("opentext_nom_pagination_stalled")
			}
			startID = nextStartID
		}
	}

	normalized := make([]InventoryDevice, 0, len(devices))
	for _, device := range devices {
		normalized = append(normalized, device)
	}
	sort.Slice(normalized, func(i, j int) bool {
		left, leftOK := parseDeviceID(normalized[i].SourceObjectID)
		right, rightOK := parseDeviceID(normalized[j].SourceObjectID)
		if leftOK && rightOK && left != right {
			return left < right
		}
		return normalized[i].SourceObjectID < normalized[j].SourceObjectID
	})

	observedAt := c.now().UTC()
	queryHash, err := hashJSON(normalizedQueries(cfg.Queries))
	if err != nil {
		return Snapshot{}, runError("opentext_nom_snapshot_hash_failed")
	}
	contentHash, err := hashJSON(normalized)
	if err != nil {
		return Snapshot{}, runError("opentext_nom_snapshot_hash_failed")
	}
	collectionID := fmt.Sprintf("%s-%s", observedAt.Format("20060102T150405.000000000Z"), contentHash[:12])
	for i := range normalized {
		sourceMetadata := normalized[i].Metadata["source_metadata"].(map[string]any)
		sourceMetadata["collection_id"] = collectionID
		sourceMetadata["last_observed_at"] = observedAt.Format(time.RFC3339Nano)
	}

	attachmentDevices := c.collectAttachedSwitchPorts(ctx, cfg)

	return Snapshot{
		InstanceID:        cfg.InstanceID,
		CollectionID:      collectionID,
		ObservedAt:        observedAt,
		QueryHash:         queryHash,
		ContentHash:       contentHash,
		Devices:           normalized,
		Pages:             pages,
		ReceivedRows:      receivedRows,
		InvalidRows:       invalidRows,
		DuplicateRows:     duplicateRows,
		SnapshotComplete:  true,
		AttachmentDevices: attachmentDevices,
	}, nil
}

func (c *Collector) fetchPage(
	ctx context.Context,
	cfg Config,
	query Query,
	startID int64,
) ([]map[string]any, int, error) {
	parameters := wireQueryParameters(query.Parameters)
	parameters["limitcount"] = cfg.PageSize
	if startID > 0 {
		parameters["startid"] = startID
	}
	payload, err := json.Marshal(map[string]any{
		"command":    "list device",
		"parameters": parameters,
	})
	if err != nil {
		return nil, 0, runError("opentext_nom_request_invalid")
	}

	response, err := c.doWithRetry(ctx, cfg, HTTPRequest{
		Method: http.MethodPost,
		URL:    cfg.APIURL,
		Headers: map[string]string{
			"Accept":       "application/json",
			"Content-Type": "application/json",
		},
		Body:      payload,
		TimeoutMS: cfg.RequestTimeoutSeconds * 1000,
	})
	if err != nil {
		return nil, 0, err
	}
	if response.Status != http.StatusOK {
		return nil, response.Status, nil
	}

	rows, err := decodeDeviceRows(response.Body)
	if err != nil {
		return nil, response.Status, runError("opentext_nom_response_invalid")
	}
	return rows, response.Status, nil
}

func (c *Collector) doWithRetry(ctx context.Context, cfg Config, request HTTPRequest) (HTTPResponse, error) {
	request.InsecureSkipVerify = cfg.InsecureSkipVerify
	for attempt := 0; attempt <= cfg.MaxRetries; attempt++ {
		response, err := c.HTTP.Do(ctx, request)
		if err == nil && response.Status != http.StatusTooManyRequests && response.Status < 500 {
			return response, nil
		}
		if attempt == cfg.MaxRetries {
			return HTTPResponse{}, runError("opentext_nom_upstream_unavailable")
		}
		if err := c.sleep(ctx, time.Duration(1<<attempt)*100*time.Millisecond); err != nil {
			return HTTPResponse{}, runError("opentext_nom_request_canceled")
		}
	}
	return HTTPResponse{}, runError("opentext_nom_upstream_unavailable")
}

func (c *Collector) now() time.Time {
	if c.Now == nil {
		return time.Now()
	}
	return c.Now()
}

func (c *Collector) sleep(ctx context.Context, delay time.Duration) error {
	if c.Sleep == nil {
		return sleepWithContext(ctx, delay)
	}
	return c.Sleep(ctx, delay)
}

func decodeDeviceRows(body []byte) ([]map[string]any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.UseNumber()
	var raw any
	if err := decoder.Decode(&raw); err != nil {
		return nil, err
	}

	if object, ok := raw.(map[string]any); ok {
		for _, key := range []string{"result", "data", "devices"} {
			if value, exists := object[key]; exists {
				raw = value
				break
			}
		}
	}
	values, ok := raw.([]any)
	if !ok {
		return nil, errors.New("device response is not an array")
	}
	rows := make([]map[string]any, 0, len(values))
	for _, value := range values {
		row, ok := value.(map[string]any)
		if !ok {
			return nil, errors.New("device response contains a non-object row")
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func normalizeDeviceRow(raw map[string]any) (networkAutomationDeviceRow, bool) {
	serials := splitSerials(valueString(raw, "serialNumber", "serial", "chassisSerial"))
	serial := ""
	if len(serials) > 0 {
		serial = serials[0]
	}
	row := networkAutomationDeviceRow{
		DeviceID:         valueString(raw, "deviceID", "deviceId", "id"),
		Hostname:         valueString(raw, "hostName", "hostname", "name"),
		IP:               valueString(raw, "primaryIPAddress", "primaryIpAddress", "ipAddress", "ip"),
		MAC:              valueString(raw, "primaryMACAddress", "primaryMacAddress", "macAddress", "mac"),
		Serial:           serial,
		ChassisSerials:   serials,
		Vendor:           valueString(raw, "vendor", "vendorName"),
		Model:            valueString(raw, "model", "deviceModel"),
		DeviceType:       valueString(raw, "deviceType", "type"),
		Partition:        valueString(raw, "siteName", "partition", "partitionName"),
		ManagementStatus: normalizeManagementStatus(valueString(raw, "managementStatus", "status")),
		ExcludeFromPoll:  valueBool(raw, "excludeFromPoll", "pollExcluded"),
		SoftwareVersion:  valueString(raw, "softwareVersion", "software_version"),
		FirmwareVersion:  valueString(raw, "firmwareVersion", "firmware_version"),
		DriverName:       valueString(raw, "driverName", "driver_name"),
		ROMVersion:       valueString(raw, "rOMVersion", "romVersion", "rom_version"),
		Processor:        valueString(raw, "processor"),
		MemoryBytes:      valueInt64(raw, "memory", "memoryBytes", "memory_bytes"),
		TotalPorts:       valueInt64(raw, "totalPorts", "total_ports"),
		FreePorts:        valueInt64(raw, "freePorts", "free_ports"),
		Contact:          valueString(raw, "contact"),
		GeoLocation:      valueString(raw, "geographicalLocation", "geographical_location"),
	}
	if row.DeviceID == "" {
		return networkAutomationDeviceRow{}, false
	}
	if row.Hostname == "" && row.IP == "" && row.MAC == "" && row.Serial == "" {
		return networkAutomationDeviceRow{}, false
	}
	return row, true
}

func inventoryDevice(instanceID string, row networkAutomationDeviceRow) InventoryDevice {
	integrationID := fmt.Sprintf(
		"opentext-nom:v1:%s:device:%s",
		instanceID,
		row.DeviceID,
	)
	managed := managedFlag(row.ManagementStatus)
	sourceMetadata := compactMap(map[string]any{
		"instance_id":           instanceID,
		"partition":             row.Partition,
		"management_status":     row.ManagementStatus,
		"exclude_from_poll":     row.ExcludeFromPoll,
		"software_version":      row.SoftwareVersion,
		"firmware_version":      row.FirmwareVersion,
		"driver_name":           row.DriverName,
		"geographical_location": row.GeoLocation,
		"chassis_serials":       row.ChassisSerials,
	})
	metadata := compactMap(map[string]any{
		"integration_id":   integrationID,
		"integration_type": "opentext-nom",
		"serial_number":    row.Serial,
		"chassis_serials":  row.ChassisSerials,
		"os_name":          firstNonEmpty(row.DriverName, row.SoftwareVersion),
		"os_version":       firstNonEmpty(row.SoftwareVersion, row.FirmwareVersion),
		"firmware_version": row.FirmwareVersion,
		"sys_contact":      row.Contact,
		"is_managed":       managed,
		"os":               deviceOS(row),
		"hw_info":          deviceHardware(row),
		"owner":            deviceOwner(row.Contact),
		"source_metadata":  sourceMetadata,
	})
	return InventoryDevice{
		IntegrationID:    integrationID,
		SourceObjectID:   row.DeviceID,
		Hostname:         row.Hostname,
		IP:               row.IP,
		MAC:              row.MAC,
		Serial:           row.Serial,
		Vendor:           row.Vendor,
		Model:            row.Model,
		DeviceType:       row.DeviceType,
		Partition:        row.Partition,
		ManagementStatus: row.ManagementStatus,
		ExcludeFromPoll:  row.ExcludeFromPoll,
		Metadata:         metadata,
	}
}

func deviceOS(row networkAutomationDeviceRow) map[string]any {
	return compactMap(map[string]any{
		"name":     row.DriverName,
		"version":  firstNonEmpty(row.SoftwareVersion, row.FirmwareVersion),
		"firmware": row.FirmwareVersion,
	})
}

func deviceHardware(row networkAutomationDeviceRow) map[string]any {
	return compactMap(map[string]any{
		"serial_number":    row.Serial,
		"chassis_serials":  row.ChassisSerials,
		"processor":        row.Processor,
		"memory_bytes":     row.MemoryBytes,
		"total_ports":      row.TotalPorts,
		"free_ports":       row.FreePorts,
		"driver_name":      row.DriverName,
		"firmware_version": row.FirmwareVersion,
		"rom_version":      row.ROMVersion,
	})
}

func deviceOwner(contact string) map[string]any {
	return compactMap(map[string]any{"name": contact})
}

func compactMap(values map[string]any) map[string]any {
	for key, value := range values {
		if emptyInventoryValue(value) {
			delete(values, key)
		}
	}
	if len(values) == 0 {
		return nil
	}
	return values
}

func emptyInventoryValue(value any) bool {
	switch typed := value.(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(typed) == ""
	case []string:
		return len(typed) == 0
	case *int64:
		return typed == nil
	case *bool:
		return typed == nil
	case map[string]any:
		return len(typed) == 0
	default:
		return false
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func splitSerials(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ';' || r == '|'
	})
	serials := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		serial := strings.TrimSpace(part)
		if serial == "" {
			continue
		}
		if _, exists := seen[serial]; exists {
			continue
		}
		seen[serial] = struct{}{}
		serials = append(serials, serial)
	}
	if len(serials) == 0 {
		return nil
	}
	return serials
}

func managedFlag(status string) *bool {
	switch status {
	case "Managed":
		value := true
		return &value
	case "Unmanaged":
		value := false
		return &value
	default:
		return nil
	}
}

func sameInventoryDevice(left, right InventoryDevice) bool {
	leftJSON, leftErr := json.Marshal(left)
	rightJSON, rightErr := json.Marshal(right)
	return leftErr == nil && rightErr == nil && string(leftJSON) == string(rightJSON)
}

func valueString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		value, exists := values[key]
		if !exists || value == nil {
			continue
		}
		switch typed := value.(type) {
		case string:
			return strings.TrimSpace(typed)
		case json.Number:
			return typed.String()
		case float64:
			return strconv.FormatFloat(typed, 'f', -1, 64)
		case int:
			return strconv.Itoa(typed)
		case int64:
			return strconv.FormatInt(typed, 10)
		}
	}
	return ""
}

func valueInt64(values map[string]any, keys ...string) *int64 {
	for _, key := range keys {
		value, exists := values[key]
		if !exists || value == nil {
			continue
		}
		switch typed := value.(type) {
		case json.Number:
			parsed, err := typed.Int64()
			if err == nil {
				result := parsed
				return &result
			}
		case int64:
			result := typed
			return &result
		case int:
			result := int64(typed)
			return &result
		case float64:
			if typed == float64(int64(typed)) {
				result := int64(typed)
				return &result
			}
		case string:
			parsed, err := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
			if err == nil {
				result := parsed
				return &result
			}
		}
	}
	return nil
}

func valueBool(values map[string]any, keys ...string) *bool {
	for _, key := range keys {
		value, exists := values[key]
		if !exists || value == nil {
			continue
		}
		switch typed := value.(type) {
		case bool:
			result := typed
			return &result
		case string:
			parsed, err := strconv.ParseBool(strings.TrimSpace(typed))
			if err == nil {
				return &parsed
			}
			if parsed, ok := intFlagBool(strings.TrimSpace(typed)); ok {
				return parsed
			}
		case json.Number:
			if parsed, ok := intFlagBool(typed.String()); ok {
				return parsed
			}
		case float64:
			if typed == float64(int64(typed)) {
				if parsed, ok := intFlagBool(strconv.FormatInt(int64(typed), 10)); ok {
					return parsed
				}
			}
		case int:
			if parsed, ok := intFlagBool(strconv.Itoa(typed)); ok {
				return parsed
			}
		case int64:
			if parsed, ok := intFlagBool(strconv.FormatInt(typed, 10)); ok {
				return parsed
			}
		}
	}
	return nil
}

func intFlagBool(raw string) (*bool, bool) {
	switch raw {
	case "0":
		value := false
		return &value, true
	case "1":
		value := true
		return &value, true
	default:
		return nil, false
	}
}

func normalizeManagementStatus(raw string) string {
	switch strings.TrimSpace(raw) {
	case "0", "Managed", "managed", "Active", "active", "Online", "online":
		return "Managed"
	case "1", "Unmanaged", "unmanaged", "Disabled", "disabled", "Inactive", "inactive", "Offline", "offline":
		return "Unmanaged"
	default:
		return strings.TrimSpace(raw)
	}
}

func parseDeviceID(value string) (int64, bool) {
	parsed, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	return parsed, err == nil && parsed > 0
}

func normalizedQueries(queries []Query) []Query {
	result := make([]Query, 0, len(queries))
	for _, query := range queries {
		result = append(result, Query{
			Name:       strings.TrimSpace(query.Name),
			Parameters: normalizedQueryParameters(query.Parameters),
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func hashJSON(value any) (string, error) {
	payload, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	digest := sumSHA256(payload)
	return hex.EncodeToString(digest[:]), nil
}
