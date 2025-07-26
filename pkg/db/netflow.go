/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"errors"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Database errors
var (
	ErrNilConnection = errors.New("database connection is nil")
	ErrPrepareBatch  = errors.New("failed to prepare batch")
	ErrAppendMetric  = errors.New("failed to append NetFlow metric")
	ErrSendBatch     = errors.New("failed to send batch")
)

// StoreNetflowMetrics stores multiple NetFlow metrics in a single batch.
func (db *DB) StoreNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	if db.Conn == nil {
		return ErrNilConnection
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO netflow_metrics (* except _tp_time)")
	if err != nil {
		return errors.Join(ErrPrepareBatch, err)
	}

	for _, metric := range metrics {
		err = batch.Append(
			metric.Timestamp,
			metric.SrcAddr,
			metric.DstAddr,
			metric.SrcPort,
			metric.DstPort,
			metric.Protocol,
			metric.Bytes,
			metric.Packets,
			metric.ForwardingStatus,
			metric.NextHop,
			metric.SamplerAddress,
			metric.SrcAs,
			metric.DstAs,
			metric.IPTos,
			metric.VlanID,
			metric.BgpNextHop,
			metric.Metadata,
		)
		if err != nil {
			db.logger.Error().Err(err).Msg("Failed to append NetFlow metric")
			return errors.Join(ErrAppendMetric, err)
		}
	}

	if err := batch.Send(); err != nil {
		db.logger.Error().Err(err).Msg("Failed to send batch")
		return errors.Join(ErrSendBatch, err)
	}

	return nil
}
