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
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// worker sends SYN packets to targets from the work channel
func (s *SYNScanner) worker(ctx context.Context, workCh <-chan models.Target) {
	pending := make([]models.Target, 0, s.sendBatchSize)

	for {
		// If we have nothing pending, block for one item or exit
		if len(pending) == 0 {
			select {
			case <-ctx.Done():
				return
			case first, ok := <-workCh:
				if !ok {
					return
				}

				pending = append(pending, first)
			}
		}

		// Non-blocking drain to fill the batch
	drain:
		for len(pending) < s.sendBatchSize {
			select {
			case t, ok := <-workCh:
				if !ok { // channel closed: stop draining now
					break drain
				}

				pending = append(pending, t)
			default:
				break drain
			}
		}

		// Rate-limited send using sendmmsg (first attempts only)
		allowed := s.allowN(len(pending))
		if allowed == 0 {
			// tiny nap to let tokens accrue
			s.recordRateLimitWait(rateLimitBackoff)
			time.Sleep(rateLimitBackoff)

			continue
		}

		// Slice to send now
		toSend := pending[:allowed]
		sent := s.sendSynBatch(ctx, toSend)

		// Enqueue retries for what we *actually* sent now
		s.enqueueRetriesForBatch(sent)

		// Remove the sent prefix; keep remainder for next loop
		pending = pending[allowed:]
	}
}

// listenForReplies pumps all ring readers (ctx-driven)
func (s *SYNScanner) listenForReplies(ctx context.Context) {
	var wg sync.WaitGroup

	for _, r := range s.rings {
		wg.Add(1)

		go func(rr *ringBuf) {
			defer wg.Done()

			s.runRingReader(ctx, rr)
		}(r)
	}

	<-ctx.Done()
	wg.Wait()
}
