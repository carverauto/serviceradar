package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func sendBatchExecAll(ctx context.Context, batch *pgx.Batch, send func(context.Context, *pgx.Batch) pgx.BatchResults, operation string) (err error) {
	if batch == nil || batch.Len() == 0 {
		return nil
	}

	br := send(ctx, batch)
	defer func() {
		if closeErr := br.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("%s batch close: %w", operation, closeErr)
		}
	}()

	for i := 0; i < batch.Len(); i++ {
		if _, err = br.Exec(); err != nil {
			return fmt.Errorf("%s batch exec (command %d): %w", operation, i, err)
		}
	}

	return nil
}
