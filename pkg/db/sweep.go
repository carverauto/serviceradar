package db

import (
	"context"
	"fmt"
	"log"
	"time"
)

// SweepResult represents a single sweep result to be stored.
type SweepResult struct {
	AgentID         string
	PollerID        string
	DiscoverySource string
	IP              string
	MAC             *string
	Hostname        *string
	Timestamp       time.Time
	Available       bool
	Metadata        map[string]string
}

func (db *DB) StoreSweepResults(ctx context.Context, results []*SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO sweep_results (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, result := range results {
		// Validate required fields
		if result.IP == "" {
			log.Printf("Skipping sweep result with empty IP for poller %s", result.PollerID)
			continue
		}

		if result.AgentID == "" {
			log.Printf("Skipping sweep result with empty AgentID for IP %s", result.IP)
			continue
		}

		if result.PollerID == "" {
			log.Printf("Skipping sweep result with empty PollerID for IP %s", result.IP)
			continue
		}

		// Ensure Metadata is a map[string]string; use empty map if nil
		metadata := result.Metadata
		if metadata == nil {
			metadata = make(map[string]string)
		}

		err = batch.Append(
			result.AgentID,
			result.PollerID,
			result.DiscoverySource,
			result.IP,
			result.MAC,
			result.Hostname,
			result.Timestamp,
			result.Available,
			metadata, // Pass map[string]string directly
		)
		if err != nil {
			log.Printf("Failed to append sweep result for IP %s: %v", result.IP, err)
			continue
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	log.Printf("Successfully stored %d sweep results", len(results))

	return nil
}
