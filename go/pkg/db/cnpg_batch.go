package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func (db *DB) sendCNPG(ctx context.Context, batch *pgx.Batch, name string) (err error) {
	br := db.pgPool.SendBatch(ctx, batch)
	defer func() {
		if closeErr := br.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("cnpg %s batch close: %w", name, closeErr)
		}
	}()

	for i := 0; i < batch.Len(); i++ {
		if _, err = br.Exec(); err != nil {
			return fmt.Errorf("cnpg %s insert (command %d): %w", name, i, err)
		}
	}

	return nil
}
