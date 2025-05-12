package db

import (
	"context"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
)

// StoreNetflowMetrics stores multiple NetFlow metrics in a single batch.
func (db *DB) StoreNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	if db.Conn == nil {
		return fmt.Errorf("database connection is nil")
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO netflow_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
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
			metric.IpTos,
			metric.VlanId,
			metric.BgpNextHop,
			metric.Metadata,
		)
		if err != nil {
			log.Printf("Failed to append NetFlow metric: %v", err)
			return fmt.Errorf("failed to append NetFlow metric: %w", err)
		}
	}

	if err := batch.Send(); err != nil {
		log.Printf("Failed to send batch: %v", err)
		return fmt.Errorf("failed to send batch: %w", err)
	}

	return nil
}
