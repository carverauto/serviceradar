//go:build linux
// +build linux

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

package scan

import (
	"context"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// ScanStream consumes targets incrementally and runs the existing SYN packet
// engine in bounded batches. This keeps large sweeps from forcing callers to
// materialize every host/port pair before scanning.
func (s *SYNScanner) ScanStream(
	ctx context.Context,
	targets <-chan models.Target,
	opts StreamOptions,
) (<-chan models.Result, <-chan error, error) {
	return scanStreamBatched(ctx, targets, opts, s.Scan)
}

type scanBatchFunc func(context.Context, []models.Target) (<-chan models.Result, error)

func scanStreamBatched(
	ctx context.Context,
	targets <-chan models.Target,
	opts StreamOptions,
	scanBatch scanBatchFunc,
) (<-chan models.Result, <-chan error, error) {
	batchSize := opts.BatchSize
	if batchSize <= 0 {
		batchSize = 100000
	}

	resultBuffer := batchSize
	if resultBuffer > 10000 {
		resultBuffer = 10000
	}

	resultCh := make(chan models.Result, resultBuffer)
	errCh := make(chan error, 1)

	go func() {
		defer close(resultCh)
		defer close(errCh)

		batch := make([]models.Target, 0, batchSize)

		flush := func() error {
			if len(batch) == 0 {
				return nil
			}

			results, err := scanBatch(ctx, batch)
			if err != nil {
				return err
			}

			for result := range results {
				select {
				case resultCh <- result:
				case <-ctx.Done():
					return ctx.Err()
				}
			}

			batch = batch[:0]

			return nil
		}

		for {
			select {
			case target, ok := <-targets:
				if !ok {
					if err := flush(); err != nil {
						errCh <- err
					}

					return
				}

				if target.Mode != models.ModeTCP {
					continue
				}

				batch = append(batch, target)
				if len(batch) >= batchSize {
					if err := flush(); err != nil {
						errCh <- err

						return
					}
				}

			case <-ctx.Done():
				errCh <- ctx.Err()

				return
			}
		}
	}()

	return resultCh, errCh, nil
}
