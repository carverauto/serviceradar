package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"time"
)

// StoreMetric stores a timeseries metric in the database.
func (db *DB) StoreMetric(nodeID string, metric *TimeseriesMetric) error {
	log.Printf("Storing metric: %v", metric)

	// Convert metadata to JSON if present
	var metadataJSON sql.NullString

	if metric.Metadata != nil {
		metadata, err := json.Marshal(metric.Metadata)
		if err != nil {
			return fmt.Errorf("failed to marshal metadata: %w", err)
		}

		metadataJSON.String = string(metadata)
		metadataJSON.Valid = true
	}

	_, err := db.Exec(`
        INSERT INTO timeseries_metrics
            (node_id, metric_name, metric_type, value, metadata, timestamp)
        VALUES (?, ?, ?, ?, ?, ?)`,
		nodeID,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataJSON,
		metric.Timestamp,
	)

	if err != nil {
		// Use %w for error wrapping
		return fmt.Errorf("failed to store metric %s for node %s: %w", metric.Name, nodeID, err)
	}

	// Log successful storage *after* the operation succeeds
	log.Printf("Successfully stored metric %s for node %s", metric.Name, nodeID)

	return nil
}

// GetMetrics retrieves metrics for a specific node and metric name.
func (db *DB) GetMetrics(nodeID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ?
        AND metric_name = ?
        AND timestamp BETWEEN ? AND ?`,
		nodeID,
		metricName,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}
	defer CloseRows(rows) // Use the helper function

	return db.scanMetrics(rows)
}

// GetMetricsByType retrieves metrics for a specific node and metric type.
func (db *DB) GetMetricsByType(nodeID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ?
        AND metric_type = ?
        AND timestamp BETWEEN ? AND ?`,
		nodeID,
		metricType,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}
	defer CloseRows(rows) // Use the helper function

	return db.scanMetrics(rows)
}

// scanMetrics is a helper function to scan rows into TimeseriesMetric slices.
func (*DB) scanMetrics(rows Rows) ([]TimeseriesMetric, error) {
	var metrics []TimeseriesMetric

	for rows.Next() {
		var metric TimeseriesMetric
		var metadataJSON sql.NullString // Use sql.NullString to handle potential NULLs

		err := rows.Scan(
			&metric.Name,
			&metric.Type,
			&metric.Value,
			&metadataJSON,
			&metric.Timestamp,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan metric row: %w", err)
		}

		// Parse metadata JSON if present and valid
		if metadataJSON.Valid && metadataJSON.String != "" {
			// Use json.RawMessage to preserve the structure for flexibility
			var rawMetadata json.RawMessage
			if err := json.Unmarshal([]byte(metadataJSON.String), &rawMetadata); err != nil {
				// Log the error but don't fail the whole query, maybe just skip metadata
				log.Printf("Warning: failed to unmarshal metadata for metric %s: %v. Raw: %s", metric.Name, err, metadataJSON.String)
			} else {
				metric.Metadata = rawMetadata // Assign the raw JSON
			}
		}

		metrics = append(metrics, metric)
	}

	// Check for errors during row iteration
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return metrics, nil
}

const (
	rperfMetricsStored        = 3   // Number of metrics stored per rperf result (bandwidth, jitter, loss)
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// rperfWrapper defines the outer structure received from the agent for rperf checks.
type rperfWrapper struct {
	Status       string `json:"status"` // This holds the nested JSON string with actual results
	ResponseTime int64  `json:"response_time"`
	Available    bool   `json:"available"`
}

// StoreRperfMetrics stores rperf-checker data as timeseries metrics.
// It now correctly handles the nested JSON structure.
func (db *DB) StoreRperfMetrics(nodeID, serviceName, message string, timestamp time.Time) error {
	log.Printf("Processing rperf metrics for node %s, servicename: %s", nodeID, serviceName)
	log.Printf("Raw message received: %s", message) // Log the raw message first

	// 1. Unmarshal the outer wrapper structure
	var wrapper rperfWrapper
	if err := json.Unmarshal([]byte(message), &wrapper); err != nil {
		log.Printf("Failed to unmarshal outer rperf wrapper for node %s: %v", nodeID, err)
		// Don't return error here if the outer structure fails, maybe log and continue?
		// Or return a specific error indicating format issue? For now, log and return.
		return fmt.Errorf("failed to unmarshal rperf wrapper message: %w", err)
	}

	// Check if the nested status string is empty
	if wrapper.Status == "" {
		log.Printf("No nested status found in rperf message for node %s", nodeID)
		// Decide if this is an error or just means no results. Log and return nil for now.
		return nil
	}

	log.Printf("Nested status string extracted for node %s: %s", nodeID, wrapper.Status)

	// 2. Unmarshal the nested JSON string from the 'status' field
	var rperfData struct {
		Results   []RperfMetric `json:"results"`
		Timestamp string        `json:"timestamp"` // Capture the timestamp from the nested data as well if needed
	}
	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		log.Printf("Failed to unmarshal nested rperf data ('status' field) for node %s: %v", nodeID, err)
		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	log.Printf("Successfully unmarshaled nested rperf data for node %s: %d results", nodeID, len(rperfData.Results))

	if len(rperfData.Results) == 0 {
		log.Printf("No rperf results found in nested data for node %s", nodeID)
		return nil // Not an error, just no results to store
	}

	// 3. Process and store each result as metrics
	storedCount := 0
	for i, result := range rperfData.Results {
		log.Printf("Processing rperf result %d for node %s: Target=%s, Success=%t", i, nodeID, result.Target, result.Success)

		// Skip storing metrics if the test itself reported failure
		if !result.Success {
			log.Printf("Skipping metrics storage for failed rperf test (Target: %s) on node %s. Error: %s",
				result.Target, nodeID, result.Error)
			continue // Move to the next result
		}

		// --- Prepare metrics ---
		metricsToStore := []struct {
			Name  string
			Value string
		}{
			{
				Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.2f", result.BitsPerSec/rperfBitsPerSecondDivisor),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.2f", result.JitterMs),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.1f", result.LossPercent),
			},
		}

		// Marshal the *individual* result as metadata for all related metrics
		// Use json.RawMessage for efficiency if storing as raw JSON
		metadataBytes, err := json.Marshal(result)
		if err != nil {
			// Log error but maybe continue storing other metrics? Or fail the batch?
			log.Printf("ERROR: Failed to marshal rperf result metadata for node %s, target %s: %v. Skipping metrics for this result.", nodeID, result.Target, err)
			continue // Skip this specific result's metrics
		}
		metadata := json.RawMessage(metadataBytes)

		// --- Store each metric ---
		for _, m := range metricsToStore {
			metric := &TimeseriesMetric{
				Name:      m.Name,
				Type:      "rperf", // Consistent type for all rperf metrics
				Value:     m.Value,
				Timestamp: timestamp, // Use the timestamp passed from the core service
				Metadata:  metadata,  // Store the full result as metadata
			}

			if err := db.StoreMetric(nodeID, metric); err != nil {
				// Log the specific error but try to continue with other metrics/results
				log.Printf("ERROR: Failed to store rperf metric %s for node %s: %v", m.Name, nodeID, err)
				// Decide whether to return the error immediately or collect errors
				// return fmt.Errorf("failed to store rperf metric %s: %w", m.Name, err) // Option: Fail fast
			} else {
				storedCount++
			}
		}
	}

	log.Printf("Finished processing rperf metrics for node %s. Stored %d metrics.", nodeID, storedCount)

	return nil
}
