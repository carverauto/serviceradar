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

package sweeper

import (
	"context"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func (s *NetworkSweeper) scanAndProcess(ctx context.Context, wg *sync.WaitGroup,
	scanner scan.Scanner, targets []models.Target, scanType string) error {
	defer wg.Done()

	return s.scanAndProcessBatch(ctx, scanner, targets, scanType)
}

func (s *NetworkSweeper) scanAndProcessBatch(ctx context.Context, scanner scan.Scanner, targets []models.Target, scanType string) error {
	s.logger.Debug().Str("scanType", scanType).Msg("Running scan")

	results, err := scanner.Scan(ctx, targets)
	if err != nil {
		s.logger.Error().Err(err).Str("scanType", scanType).Msg("Scan failed")

		return err
	}

	return s.processResultsStream(ctx, results, scanType)
}

// processResultsStream processes results from a scanner stream with batching.
func (s *NetworkSweeper) processResultsStream(ctx context.Context, results <-chan models.Result, scanType string) error {
	count := 0
	success := 0

	// Batch processing configuration
	const batchSize = 1000

	resultBatch := make([]models.Result, 0, batchSize)

	// Process results as they arrive, respecting context timeout
	for {
		select {
		case result, ok := <-results:
			if !ok {
				return s.handleStreamComplete(ctx, resultBatch, scanType, count, success)
			}

			if err := s.submitBannerGrabCandidate(ctx, result); err != nil {
				return err
			}

			count, success = s.processSingleResult(&result, &resultBatch, count, success)
			if err := s.processBatchIfFull(ctx, &resultBatch, scanType, count, success); err != nil {
				return err
			}

		case <-ctx.Done():
			return s.handleContextDone(ctx, resultBatch, scanType, count, success)
		}
	}
}
