package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// collectDataUsage fetches current-month data-usage per service line and
// data-pool capacity/usage, returning metric records attributed to terminal
// devices. Best-effort: individual API failures are silently skipped.
func collectDataUsage(c *apiClient, snap *inventorySnapshot, instance string, now time.Time) []sdk.TelemetryRecord {
	slToTerminal := slTerminalMap(snap)
	poolToTerminals := poolTerminalMap(snap)

	var records []sdk.TelemetryRecord

	slNumbers := make([]string, 0, len(snap.ServiceLines))
	for num := range snap.ServiceLines {
		slNumbers = append(slNumbers, num)
	}
	if len(slNumbers) > 0 {
		records = append(records, queryDataUsage(c, slNumbers, slToTerminal, instance, now)...)
	}
	records = append(records, collectPoolMetrics(c, poolToTerminals, instance, now)...)
	return records
}

func slTerminalMap(snap *inventorySnapshot) map[string]string {
	m := map[string]string{}
	for _, t := range snap.Terminals {
		if t.ServiceLine != "" {
			m[t.ServiceLine] = terminalIDPrefix + t.ID
		}
	}
	return m
}

func poolTerminalMap(snap *inventorySnapshot) map[string][]string {
	m := map[string][]string{}
	for _, t := range snap.Terminals {
		sl, ok := snap.ServiceLines[t.ServiceLine]
		if !ok || sl.DataPoolID == "" {
			continue
		}
		devID := terminalIDPrefix + t.ID
		m[sl.DataPoolID] = append(m[sl.DataPoolID], devID)
	}
	return m
}

func queryDataUsage(c *apiClient, slNumbers []string, slToTerminal map[string]string, instance string, now time.Time) []sdk.TelemetryRecord {
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	end := start.AddDate(0, 1, -1)

	body := `{"serviceLineNumbers":` + stringsJSON(slNumbers) +
		`,"startDate":"` + start.Format("2006-01-02") +
		`","endDate":"` + end.Format("2006-01-02") + `"}`

	content, err := c.call(http.MethodPost, "/data-usage/query", nil, []byte(body), 0)
	if err != nil {
		return nil
	}

	atNano := uint64(now.UnixNano())
	var records []sdk.TelemetryRecord
	content.Get("dataUsages").ForEach(func(_, item gjson.Result) bool {
		slNum := trimmed(item, "serviceLineNumber")
		devID, ok := slToTerminal[slNum]
		if !ok || devID == "" {
			return true
		}

		dlPriority := item.Get("downloadPriorityGB").Float()
		ulPriority := item.Get("uploadPriorityGB").Float()
		dlStandard := item.Get("downloadStandardGB").Float()
		ulStandard := item.Get("uploadStandardGB").Float()
		budgetGB := item.Get("budgetGB").Float()

		priorityGB := dlPriority + ulPriority
		totalGB := dlPriority + ulPriority + dlStandard + ulStandard

		metrics := []sdk.Metric{
			{Name: "starlink_data_usage_priority_gb", Kind: sdk.MetricKindGauge, Unit: "GB",
				Points: []sdk.MetricPoint{{Value: priorityGB, ObservedAtUnixNano: atNano}}},
			{Name: "starlink_data_usage_total_gb", Kind: sdk.MetricKindGauge, Unit: "GB",
				Points: []sdk.MetricPoint{{Value: totalGB, ObservedAtUnixNano: atNano}}},
		}
		if budgetGB > 0 {
			metrics = append(metrics, sdk.Metric{
				Name:   "starlink_data_budget_priority_gb",
				Kind:   sdk.MetricKindGauge,
				Unit:   "GB",
				Points: []sdk.MetricPoint{{Value: budgetGB, ObservedAtUnixNano: atNano}},
			})
		}

		records = append(records, sdk.NewServiceRadarMetricTelemetryRecordFromBatch(
			"starlink-datausage-"+devID+"-"+strconv.FormatUint(atNano, 10),
			sdk.MetricBatch{
				Resource: sdk.MetricResource{
					ServiceName: sourceName,
					ServiceType: "wasm-plugin",
					DeviceID:    devID,
					Attributes: []sdk.MetricStringMapEntry{
						{Key: "plugin_id", Value: cloudPluginID},
						{Key: "source_instance", Value: instance},
						{Key: "service_line_number", Value: slNum},
					},
				},
				IngestIdentity: sdk.MetricIngestIdentity{
					Source:       "plugin-metrics",
					ProducerID:   cloudPluginID,
					ProducerKind: "wasm-plugin",
				},
				Metrics: metrics,
			},
		))
		return true
	})
	return records
}

func collectPoolMetrics(c *apiClient, poolToTerminals map[string][]string, instance string, now time.Time) []sdk.TelemetryRecord {
	if len(poolToTerminals) == 0 {
		return nil
	}

	atNano := uint64(now.UnixNano())

	poolCap := map[string]float64{}
	if content, err := c.call(http.MethodGet, "/data-pools", nil, nil, 0); err == nil {
		content.Get("dataPools").ForEach(func(_, pool gjson.Result) bool {
			if id := trimmed(pool, "dataPoolId"); id != "" {
				poolCap[id] = pool.Get("capacityGB").Float()
			}
			return true
		})
	}

	var records []sdk.TelemetryRecord
	for poolID, terminals := range poolToTerminals {
		if !jsonSafeID(poolID) {
			continue
		}
		usageContent, err := c.call(http.MethodGet, "/data-pools/"+poolID+"/usage", nil, nil, 0)
		if err != nil {
			continue
		}
		usedGB := usageContent.Get("usedGB").Float()
		remainingGB := usageContent.Get("remainingGB").Float()
		capacityGB := poolCap[poolID]

		for _, devID := range terminals {
			records = append(records, sdk.NewServiceRadarMetricTelemetryRecordFromBatch(
				"starlink-pool-"+devID+"-"+strconv.FormatUint(atNano, 10),
				sdk.MetricBatch{
					Resource: sdk.MetricResource{
						ServiceName: sourceName,
						ServiceType: "wasm-plugin",
						DeviceID:    devID,
						Attributes: []sdk.MetricStringMapEntry{
							{Key: "plugin_id", Value: cloudPluginID},
							{Key: "source_instance", Value: instance},
							{Key: "data_pool_id", Value: poolID},
						},
					},
					IngestIdentity: sdk.MetricIngestIdentity{
						Source:       "plugin-metrics",
						ProducerID:   cloudPluginID,
						ProducerKind: "wasm-plugin",
					},
					Metrics: []sdk.Metric{
						{Name: "starlink_pool_capacity_gb", Kind: sdk.MetricKindGauge, Unit: "GB",
							Points: []sdk.MetricPoint{{Value: capacityGB, ObservedAtUnixNano: atNano}}},
						{Name: "starlink_pool_used_gb", Kind: sdk.MetricKindGauge, Unit: "GB",
							Points: []sdk.MetricPoint{{Value: usedGB, ObservedAtUnixNano: atNano}}},
						{Name: "starlink_pool_remaining_gb", Kind: sdk.MetricKindGauge, Unit: "GB",
							Points: []sdk.MetricPoint{{Value: remainingGB, ObservedAtUnixNano: atNano}}},
					},
				},
			))
		}
	}
	return records
}
