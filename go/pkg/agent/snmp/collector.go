/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package snmp pkg/agent/snmp/collector.go

package snmp

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const (
	defaultByteBuffer               = 1024
	defaultErrorChan                = 10
	defaultDataChanBufferMultiplier = 2
	// defaultWalkChanBufferRows is the results-channel budget for a walked OID.
	// A GET contributes one value per poll, a walk one per discovered row.
	defaultWalkChanBufferRows    = 64
	counterKindSum               = "sum"
	counterTemporalityCumulative = "cumulative"
	maxCounter32                 = uint64(1<<32 - 1)
	// walkIndexSeparator suffixes a walked row's OID index onto the configured
	// OID name. It reuses the existing "name::label" series-identity convention
	// (see ifHCInOctets::ifindex:7), so every row of a table gets its own series
	// and the index survives into the metric envelope as a tag.
	walkIndexSeparator = "::index:"
)

// NewCollector creates a new SNMP collector for a target.
func NewCollector(target *Target, log logger.Logger) (Collector, error) {
	if err := validateTarget(target); err != nil {
		return nil, fmt.Errorf("%w %w", ErrInvalidTargetConfig, err)
	}

	client, err := newSNMPClient(target)
	if err != nil {
		return nil, fmt.Errorf("%w %w", ErrSNMPConnect, err)
	}

	collector := &SNMPCollector{
		target:    target,
		client:    client,
		dataChan:  make(chan DataPoint, dataChanBuffer(target)),
		errorChan: make(chan error, defaultErrorChan),
		done:      make(chan struct{}),
		status: TargetStatus{
			OIDStatus: make(map[string]OIDStatus),
		},
		bufferPool: &sync.Pool{
			New: func() interface{} {
				return make([]byte, 0, defaultByteBuffer)
			},
		},
		logger: log,
	}

	return collector, nil
}

// dataChanBuffer sizes the results channel for a target. A GET-mode OID yields a
// single value per poll, while a walked OID yields one per discovered row, so a
// walk is budgeted a larger share to keep the poll loop from stalling on a full
// channel between drains. Get-only targets keep their previous buffer size.
func dataChanBuffer(target *Target) int {
	buffer := 0

	for i := range target.OIDs {
		if target.OIDs[i].IsWalk() {
			buffer += defaultWalkChanBufferRows

			continue
		}

		buffer += defaultDataChanBufferMultiplier
	}

	return buffer
}

// Start implements the Collector interface.
func (c *SNMPCollector) Start(ctx context.Context) error {
	// Connect to the SNMP device
	if err := c.client.Connect(); err != nil {
		return fmt.Errorf("%w - %w", ErrSNMPConnect, err)
	}

	// Start collection goroutine
	go c.collect(ctx)

	// Start error handling goroutine
	go c.handleErrors(ctx)

	return nil
}

// Stop implements the Collector interface.
func (c *SNMPCollector) Stop() error {
	c.closeOnce.Do(func() {
		close(c.done)

		if err := c.client.Close(); err != nil {
			c.logger.Error().
				Err(err).
				Str("target_name", c.target.Name).
				Msg("Error closing SNMP client")
		}
	})

	return nil
}

// GetResults implements the Collector interface.
func (c *SNMPCollector) GetResults() <-chan DataPoint {
	return c.dataChan
}

// collect runs the main collection loop.
func (c *SNMPCollector) collect(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(c.target.Interval))
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-c.done:
			return
		case <-ticker.C:
			if err := c.pollTarget(ctx); err != nil {
				select {
				case c.errorChan <- err:
				default:
					c.logger.Warn().Err(err).Msg("Error channel full, dropping error")
				}
			}
		}
	}
}

// pollTarget performs a single poll of all OIDs for the target.
func (c *SNMPCollector) pollTarget(ctx context.Context) error {
	getOIDs, walkOIDs := c.partitionOIDs()

	c.logger.Debug().
		Str("target_name", c.target.Name).
		Str("target_host", c.target.Host).
		Int("oid_count", len(c.target.OIDs)).
		Int("walk_oid_count", len(walkOIDs)).
		Msg("Polling target")

	var errs []error

	if len(getOIDs) > 0 {
		if err := c.pollGetOIDs(ctx, getOIDs); err != nil {
			errs = append(errs, err)
		}
	}

	for _, oidConfig := range walkOIDs {
		if err := c.pollWalkOID(ctx, oidConfig); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		err := errors.Join(errs...)
		c.updateStatus(false, err.Error())

		return err
	}

	c.updateStatus(true, "")

	return nil
}

// partitionOIDs splits the target's OIDs into the ones fetched in a single GET
// batch and the ones walked individually.
func (c *SNMPCollector) partitionOIDs() (getOIDs, walkOIDs []*OIDConfig) {
	getOIDs = make([]*OIDConfig, 0, len(c.target.OIDs))
	walkOIDs = make([]*OIDConfig, 0, len(c.target.OIDs))

	for i := range c.target.OIDs {
		oidConfig := &c.target.OIDs[i]

		if oidConfig.IsWalk() {
			walkOIDs = append(walkOIDs, oidConfig)

			continue
		}

		getOIDs = append(getOIDs, oidConfig)
	}

	return getOIDs, walkOIDs
}

// pollGetOIDs retrieves every GET-mode OID for the target.
func (c *SNMPCollector) pollGetOIDs(ctx context.Context, oidConfigs []*OIDConfig) error {
	oids := make([]string, len(oidConfigs))
	for i, oidConfig := range oidConfigs {
		oids[i] = oidConfig.OID
	}

	// Get SNMP data
	results, err := c.client.Get(oids)
	if err != nil {
		return fmt.Errorf("%w - %w", ErrSNMPGet, err)
	}

	c.logger.Debug().
		Str("target_name", c.target.Name).
		Int("result_count", len(results)).
		Msg("Successfully polled target, processing results")

	// Process each result
	for oid, value := range results {
		if err := c.processResult(ctx, oid, value); err != nil {
			c.logger.Error().
				Err(err).
				Str("oid", oid).
				Msg("Error processing result for OID")
		}
	}

	return nil
}

// pollWalkOID walks one OID subtree and emits a data point per discovered row.
func (c *SNMPCollector) pollWalkOID(ctx context.Context, oidConfig *OIDConfig) error {
	rows, err := c.client.Walk(oidConfig.OID, oidConfig.walkRowLimit(), oidConfig.walkTimeout())
	if err != nil {
		if !isWalkBoundError(err) {
			return fmt.Errorf("%w - %w", ErrSNMPWalk, err)
		}

		// The walk stopped at one of its bounds; the rows it did collect are
		// still valid, so report the truncation and keep them.
		c.logger.Warn().
			Err(err).
			Str("target_name", c.target.Name).
			Str("oid", oidConfig.OID).
			Int("row_count", len(rows)).
			Msg("SNMP walk stopped at a configured bound, using partial results")
	}

	c.logger.Debug().
		Str("target_name", c.target.Name).
		Str("oid", oidConfig.OID).
		Int("row_count", len(rows)).
		Msg("Successfully walked target OID, processing rows")

	// Process each row
	for i := range rows {
		if err := c.processWalkResult(ctx, oidConfig, &rows[i]); err != nil {
			c.logger.Error().
				Err(err).
				Str("oid", rows[i].OID).
				Msg("Error processing result for OID")
		}
	}

	return nil
}

// processResult handles a single OID result.
func (c *SNMPCollector) processResult(ctx context.Context, oid string, value interface{}) error {
	oidConfig := c.findOIDConfig(oid)
	if oidConfig == nil {
		return fmt.Errorf("%w %s", ErrNoOIDConfig, oid)
	}

	return c.processValue(ctx, oidConfig, oidConfig.Name, "", value)
}

// processWalkResult handles a single row discovered by a walk. Each row becomes
// its own series - the shared OID config only supplies the conversion rules, so
// the row's index has to be part of the name to keep rows from colliding in the
// aggregator and in the OID status map.
func (c *SNMPCollector) processWalkResult(ctx context.Context, oidConfig *OIDConfig, row *WalkResult) error {
	return c.processValue(ctx, oidConfig, walkPointName(oidConfig.Name, row.Index), row.Index, row.Value)
}

// walkPointName names a walked row's series after the configured OID name plus
// its row index.
func walkPointName(name, index string) string {
	if index == "" {
		return name
	}

	return name + walkIndexSeparator + index
}

// processValue converts one collected value and emits it as a data point. name
// is the series name to publish under: the OID name for a GET, or the OID name
// plus the row index for a walked row.
func (c *SNMPCollector) processValue(
	ctx context.Context, oidConfig *OIDConfig, name, index string, value interface{}) error {
	converted, err := c.convertValue(value, oidConfig)
	if err != nil {
		return fmt.Errorf("%w - %w", ErrSNMPConvert, err)
	}

	now := time.Now()
	finalValue := converted
	var rawValue interface{}
	dataType := oidConfig.DataType
	isDelta := oidConfig.Delta
	kind := ""
	temporality := ""
	isMonotonic := false
	counterWidth := counterWidth(value)

	// Counter classification is behavioral: a reading is treated as a counter only
	// when the SNMP wire type is actually Counter32/Counter64 (carried as a
	// CounterValue), not solely on operator DataType config. A Gauge32 (a bare
	// uint64) mislabeled as a counter would otherwise be differenced/wrapped,
	// feeding garbage rates to the anomaly detector. Downgrade to gauge + warn so
	// the misconfiguration is visible instead of silently corrupting the series.
	if _, isWireCounter := value.(CounterValue); dataType == TypeCounter && !isWireCounter {
		c.logger.Warn().
			Str("oid", oidConfig.OID).
			Str("name", oidConfig.Name).
			Msg("OID configured as counter but SNMP wire type is not Counter32/Counter64; treating as gauge")

		dataType = TypeGauge
		isDelta = false
	}

	if dataType == TypeCounter {
		rawValue = converted
		kind = counterKindSum
		temporality = counterTemporalityCumulative
		isMonotonic = true
		isDelta = false
	} else if oidConfig.Delta {
		c.mu.RLock()
		prevStatus, exists := c.status.OIDStatus[name]
		c.mu.RUnlock()

		if exists && prevStatus.LastValue != nil && !prevStatus.LastUpdate.IsZero() {
			elapsed := now.Sub(prevStatus.LastUpdate).Seconds()
			if elapsed > 0 {
				delta, ok := calculateDelta(prevStatus.LastValue, converted, counterWidth)
				if !ok {
					c.updateOIDStatus(name, &DataPoint{
						Value:     converted,
						Timestamp: now,
					})

					return nil
				}

				// Calculate per-second rate
				finalValue = delta / elapsed
			} else {
				// Avoid division by zero or negative time
				return nil
			}
		} else {
			// First sample, just store it and wait for next poll to calculate rate
			c.updateOIDStatus(name, &DataPoint{
				Value:     converted,
				Timestamp: now,
			})
			return nil
		}
	}

	// Apply scaling if configured. Counters keep the raw cumulative integer;
	// downstream consumers use scale only for display/query-time conversion.
	if dataType != TypeCounter && oidConfig.Scale != 0 && oidConfig.Scale != 1.0 {
		if val, ok := toFloat64(finalValue); ok {
			finalValue = val * oidConfig.Scale
		}
	}

	if oidConfig.Delta && dataType != TypeCounter {
		dataType = TypeFloat
		isDelta = false
	}

	point := DataPoint{
		OIDName:      name,
		OIDIndex:     index,
		Value:        finalValue,
		RawValue:     rawValue,
		Timestamp:    now,
		DataType:     dataType,
		Scale:        oidConfig.Scale,
		Delta:        isDelta,
		Kind:         kind,
		Temporality:  temporality,
		IsMonotonic:  isMonotonic,
		CounterWidth: counterWidth,
	}

	// Update OID status
	c.updateOIDStatus(name, &point)

	select {
	case c.dataChan <- point:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		return ErrCollectorStopped
	}
}

func calculateDelta(prev, current interface{}, width int) (float64, bool) {
	p, okP := toUint64(prev)
	c, okC := toUint64(current)
	if !okP || !okC {
		return 0, false
	}

	if c >= p {
		return float64(c - p), true
	}

	if width == 32 && p <= maxCounter32 {
		return float64((maxCounter32 - p) + c + 1), true
	}

	return 0, false
}

func toFloat64(v interface{}) (float64, bool) {
	switch val := v.(type) {
	case CounterValue:
		return float64(val.Value), true
	case float64:
		return val, true
	case uint64:
		return float64(val), true
	case int64:
		return float64(val), true
	case uint32:
		return float64(val), true
	case int32:
		return float64(val), true
	case int:
		return float64(val), true
	default:
		return 0, false
	}
}

func toUint64(v interface{}) (uint64, bool) {
	switch val := v.(type) {
	case CounterValue:
		return val.Value, true
	case uint64:
		return val, true
	case uint32:
		return uint64(val), true
	case int64:
		if val < 0 {
			return 0, false
		}

		return uint64(val), true
	case int32:
		if val < 0 {
			return 0, false
		}

		return uint64(val), true
	case int:
		if val < 0 {
			return 0, false
		}

		return uint64(val), true
	case float64:
		if val < 0 || val != float64(uint64(val)) {
			return 0, false
		}

		return uint64(val), true
	default:
		return 0, false
	}
}

func counterWidth(v interface{}) int {
	if counter, ok := v.(CounterValue); ok {
		return counter.Width
	}

	return 0
}

// convertValue converts an SNMP value based on the OID configuration.
func (c *SNMPCollector) convertValue(value interface{}, config *OIDConfig) (interface{}, error) {
	switch config.DataType {
	case TypeCounter:
		return c.convertCounter(value)
	case TypeGauge:
		return c.convertGauge(value)
	case TypeBoolean:
		return c.convertBoolean(value)
	case TypeBytes:
		return c.convertBytes(value)
	case TypeString:
		return c.convertString(value)
	case TypeFloat:
		return c.convertFloat(value)
	default:
		return nil, fmt.Errorf("%w %v", ErrUnsupportedDataType, config.DataType)
	}
}

// handleErrors processes errors from the collection process.
func (c *SNMPCollector) handleErrors(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.done:
			return
		case err := <-c.errorChan:
			c.logger.Error().
				Err(err).
				Str("target_name", c.target.Name).
				Msg("Error collecting from target")
		}
	}
}

// updateStatus updates the collector's status.
func (c *SNMPCollector) updateStatus(available bool, errorMsg string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.status.Available = available
	c.status.LastPoll = time.Now()
	c.status.Error = errorMsg
}

// updateOIDStatus updates the status for a specific OID.
func (c *SNMPCollector) updateOIDStatus(oidName string, point *DataPoint) {
	c.mu.Lock()
	defer c.mu.Unlock()

	status := c.status.OIDStatus[oidName]
	status.LastValue = point.Value
	status.LastUpdate = point.Timestamp

	c.status.OIDStatus[oidName] = status
}

// GetStatus returns the current status of the collector.
func (c *SNMPCollector) GetStatus() TargetStatus {
	c.mu.RLock()
	defer c.mu.RUnlock()

	return c.status
}

// convertCounter converts a counter value to a uint64.
func (*SNMPCollector) convertCounter(value interface{}) (uint64, error) {
	switch v := value.(type) {
	case CounterValue:
		return v.Value, nil
	case uint64:
		return v, nil
	case uint32:
		return uint64(v), nil
	case int64:
		if v < 0 {
			return 0, fmt.Errorf("%w: negative value", ErrInvalidCounterType)
		}

		return uint64(v), nil
	case int32:
		if v < 0 {
			return 0, fmt.Errorf("%w: negative value", ErrInvalidCounterType)
		}

		return uint64(v), nil
	case float64:
		if v < 0 {
			return 0, fmt.Errorf("%w: negative value", ErrInvalidCounterType)
		}

		return uint64(v), nil
	default:
		return 0, fmt.Errorf("%w: %T", ErrInvalidCounterType, value)
	}
}

func (*SNMPCollector) convertFloat(value interface{}) (float64, error) {
	switch v := value.(type) {
	case float64:
		return v, nil
	case float32:
		return float64(v), nil
	case int64:
		return float64(v), nil
	case int32:
		return float64(v), nil
	case uint64:
		return float64(v), nil
	case uint32:
		return float64(v), nil
	default:
		return 0, fmt.Errorf("%w: %T", ErrInvalidFloatType, value)
	}
}

func (c *SNMPCollector) findOIDConfig(oid string) *OIDConfig {
	for _, cfg := range c.target.OIDs {
		if cfg.OID == oid {
			return &cfg
		}
	}

	return nil
}

// convertGauge converts a gauge value to a float64.
func (*SNMPCollector) convertGauge(value interface{}) (float64, error) {
	switch v := value.(type) {
	case uint64:
		return float64(v), nil
	case int64:
		return float64(v), nil
	case float64:
		return v, nil
	case uint32:
		return float64(v), nil
	case int32:
		return float64(v), nil
	default:
		return 0, fmt.Errorf("%w %T", ErrInvalidGaugeType, value)
	}
}

// convertBoolean converts a boolean value to a bool.
func (*SNMPCollector) convertBoolean(value interface{}) (bool, error) {
	switch v := value.(type) {
	case int:
		return v != 0, nil
	case bool:
		return v, nil
	default:
		return false, fmt.Errorf("%w %T", ErrInvalidBooleanType, value)
	}
}

// convertBytes converts a byte value to a uint64.

func (*SNMPCollector) convertBytes(value interface{}) (uint64, error) {
	switch v := value.(type) {
	case uint64:
		return v, nil
	case uint32:
		return uint64(v), nil
	case int64:
		if v < 0 {
			return 0, fmt.Errorf("%w: negative value", ErrInvalidBytesType)
		}

		return uint64(v), nil
	default:
		return 0, fmt.Errorf("%w %T", ErrInvalidBytesType, value)
	}
}

// convertString converts a string value to a string.
func (*SNMPCollector) convertString(value interface{}) (string, error) {
	switch v := value.(type) {
	case []byte:
		return string(v), nil
	case string:
		return v, nil
	default:
		return "", fmt.Errorf("%w %T", ErrInvalidStringType, value)
	}
}
