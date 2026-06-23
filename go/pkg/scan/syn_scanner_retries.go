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
	"container/heap"
	"context"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

type retryItem struct {
	due    time.Time
	target models.Target
	key    string
}

type retryHeap []retryItem

func (h retryHeap) Len() int           { return len(h) }
func (h retryHeap) Less(i, j int) bool { return h[i].due.Before(h[j].due) }
func (h retryHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *retryHeap) Push(x any)        { *h = append(*h, x.(retryItem)) }
func (h *retryHeap) Pop() any {
	old := *h

	n := len(old)
	x := old[n-1]

	*h = old[:n-1]

	return x
}

// sendPendingWithLimiter uses the global limiter; it may send in chunks until *pending is empty.
func (s *SYNScanner) sendPendingWithLimiter(ctx context.Context, pending *[]models.Target) {
	for len(*pending) > 0 {
		allowed := s.allowN(len(*pending))

		// Also cap by number of free source ports to avoid hot spinning
		if s.portAlloc != nil {
			free := s.portAlloc.Free()
			if free <= 0 {
				s.recordSourcePortWait(rateLimitBackoff)
				time.Sleep(rateLimitBackoff)

				continue
			}

			if allowed > free {
				allowed = free
			}
		}

		if allowed == 0 {
			// tiny sleep to avoid busy spinning
			s.recordRateLimitWait(rateLimitBackoff)
			time.Sleep(rateLimitBackoff)

			continue
		}

		sent := s.sendSynBatch(ctx, (*pending)[:allowed])
		atomic.AddUint64(&s.stats.RetriesAttempted, uint64(len(sent)))
		*pending = (*pending)[allowed:]
	}
}

// runRetryQueue collects retry requests, wakes up when they're due, and sends them in batches via sendmmsg().
func (s *SYNScanner) runRetryQueue(ctx context.Context) {
	var pq retryHeap

	heap.Init(&pq)

	timer := time.NewTimer(time.Hour)
	if !timer.Stop() {
		<-timer.C
	}

	pending := make([]models.Target, 0, s.sendBatchSize)

	for {
		// If empty, wait for the first item or ctx cancel
		if pq.Len() == 0 {
			select {
			case <-ctx.Done():
				return
			case it := <-s.retryCh:
				if s.hasFinalResult(it.key) {
					continue
				}

				heap.Push(&pq, it)
			}

			continue
		}

		// Wait until the earliest item is due
		next := pq[0].due
		wait := time.Until(next)

		if wait < 0 {
			wait = 0
		}

		safeTimerReset(timer, wait)

		select {
		case <-ctx.Done():
			return

		case it := <-s.retryCh:
			if !s.hasFinalResult(it.key) {
				heap.Push(&pq, it)
			}

		case <-timer.C:
			// Pop due items and batch-send with limiter
			now := time.Now()

			pending = pending[:0]

			for pq.Len() > 0 {
				it := heap.Pop(&pq).(retryItem)

				if it.due.After(now) {
					// Not due; put back and stop
					heap.Push(&pq, it)

					break
				}

				if s.hasFinalResult(it.key) {
					continue
				}

				pending = append(pending, it.target)

				if len(pending) >= s.sendBatchSize {
					s.sendPendingWithLimiter(ctx, &pending)
				}
			}

			s.sendPendingWithLimiter(ctx, &pending)
		}
	}
}

// safeTimerReset stops t (draining if needed) then resets it to d.
func safeTimerReset(t *time.Timer, d time.Duration) {
	if !t.Stop() {
		select {
		case <-t.C:
		default:
		}
	}

	t.Reset(d)
}

func (s *SYNScanner) enqueueRetriesForBatch(batch []models.Target) {
	if s.retryAttempts <= 1 {
		return
	}

	s.mu.Lock()
	rc := s.retryCh
	s.mu.Unlock()

	if rc == nil {
		return
	}

	now := time.Now()
	span := s.retryMaxJitter - s.retryMinJitter

	for _, t := range batch {
		key := fmt.Sprintf("%s:%d", t.Host, t.Port)

		for attempt := 1; attempt < s.retryAttempts; attempt++ {
			d := s.retryMinJitter

			if span > 0 {
				s.randMu.Lock()
				j := s.rand.Int64N(int64(span))
				s.randMu.Unlock()

				d += time.Duration(j)
			}

			due := now.Add(time.Duration(attempt) * d)
			it := retryItem{due: due, target: t, key: key}

			select {
			case rc <- it:
			case <-time.After(2 * time.Millisecond):
				// slow path: best-effort, do not deadlock if rc drains slowly
				select {
				case rc <- it:
				default:
					// drop this retry rather than risk a stall
					atomic.AddUint64(&s.stats.RetriesDropped, 1)
				}
			}
		}
	}
}
