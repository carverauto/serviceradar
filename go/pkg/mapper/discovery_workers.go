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

package mapper

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// handleEmptyTargetList updates job status when no valid targets are found
func (e *DiscoveryEngine) handleEmptyTargetList(job *DiscoveryJob) {
	job.mu.Lock()
	job.Status.Status = DiscoveryStatusFailed
	job.Status.Error = "No valid targets to scan after processing seeds"
	job.Status.Progress = 100
	job.mu.Unlock()

	e.logger.Error().Str("job_id", job.ID).Msg("Failed - no valid targets to scan")
}

// determineConcurrency calculates the appropriate concurrency level.
func (e *DiscoveryEngine) determineConcurrency(job *DiscoveryJob, totalTargets int) int {
	concurrency := job.Params.Concurrency

	if concurrency <= 0 {
		// For small target lists (5 or fewer), use the target count
		// For large target lists (more than 5), use the worker count
		if totalTargets <= 5 {
			concurrency = totalTargets
		} else {
			concurrency = e.workers
		}
	}

	if concurrency > totalTargets {
		concurrency = totalTargets // Don't create more workers than needed
	}

	return concurrency
}

type targetProcessorFunc func(job *DiscoveryJob, targetIP string)

// startWorkers launches worker goroutines to process targets using the provided processor function.
func (e *DiscoveryEngine) startWorkers(
	job *DiscoveryJob,
	wg *sync.WaitGroup,
	targetChan <-chan string,
	resultChan chan<- bool,
	concurrency int,
	processor targetProcessorFunc,
) {
	for i := 0; i < concurrency; i++ {
		wg.Add(1)

		go func(workerID int) {
			defer wg.Done()

			for target := range targetChan {
				success := false

				select {
				case <-job.ctx.Done():
					e.logger.Info().Str("job_id", job.ID).Int("worker_id", workerID).
						Str("target", target).Msg("Worker stopping")

					return
				case <-e.done:
					e.logger.Info().Str("job_id", job.ID).Int("worker_id", workerID).
						Msg("Worker stopping - engine shutdown")

					return
				default:
					// Host probes are advisory and intentionally non-blocking for SNMP collection.
					if e.hostProber != nil {
						probeErr := e.hostProber.Probe(job.ctx, target)
						job.mu.Lock()
						job.Results.Contract.ProbeSummary.Attempts++
						if probeErr != nil {
							job.Results.Contract.ProbeSummary.Failures++
						}
						job.mu.Unlock()
						if probeErr != nil {
							e.logger.Info().Str("job_id", job.ID).
								Str("target", target).
								Err(probeErr).
								Msg("ICMP probe failed, proceeding to SNMP")
						}
					}

					// Process target with overall timeout
					targetCtx, targetCancel := context.WithTimeout(job.ctx, 2*time.Minute)

					targetDone := make(chan struct{})

					go func() {
						processor(job, target)
						close(targetDone)
					}()

					select {
					case <-targetDone:
						success = true
					case <-targetCtx.Done():
						e.logger.Warn().Str("job_id", job.ID).
							Int("worker_id", workerID).
							Str("target", target).
							Msg("Worker timeout")

						success = false
					}

					targetCancel()

					// Send result after processing target. Progress tracking relies
					// on one completion per target, so do not drop when the channel is
					// briefly full.
					select {
					case resultChan <- success:
					case <-job.ctx.Done():
						return
					case <-e.done:
						return
					}
				}
			}

			e.logger.Debug().Str("job_id", job.ID).Int("worker_id", workerID).Msg("Worker finished")
		}(i)
	}
}

// feedTargetsToWorkers sends targets to worker goroutines
// Returns true if job was canceled during feeding
func (e *DiscoveryEngine) feedTargetsToWorkers(job *DiscoveryJob, targetChan chan<- string) bool {
	for _, target := range job.scanQueue {
		select {
		case targetChan <- target:
			// Target sent to worker
		case <-job.ctx.Done():
			e.logger.Info().Str("job_id", job.ID).Msg("Stopping target feed due to cancellation")
			close(targetChan)

			return true
		case <-e.done:
			e.logger.Info().Str("job_id", job.ID).Msg("Stopping target feed due to engine shutdown")
			close(targetChan)

			return true
		}
	}

	close(targetChan)

	return false
}

// checkJobCancellation checks if the job was canceled or the engine is shutting down
// Returns true if the job was canceled
func (e *DiscoveryEngine) checkPhaseJobCancellation(job *DiscoveryJob, seedIP, phaseName string) bool {
	select {
	case <-job.ctx.Done():
		e.logger.Info().Str("job_id", job.ID).
			Str("phase", phaseName).
			Str("seed_ip", seedIP).
			Err(job.ctx.Err()).
			Msg("Phase canceled for seed")
		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoverStatusCanceled
			job.Status.Error = fmt.Sprintf("Job canceled during %s phase: %v", phaseName, job.ctx.Err())
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()

		return true
	case <-e.done:
		e.logger.Info().Str("job_id", job.ID).
			Str("phase", phaseName).
			Str("seed_ip", seedIP).
			Msg("Phase stopped due to engine shutdown for seed")
		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoveryStatusFailed
			job.Status.Error = fmt.Sprintf("Engine shutting down during %s phase", phaseName)
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()

		return true
	default:
		return false
	}
}

func recordStageTransition(job *DiscoveryJob, stage DiscoveryStage, status DiscoveryStageStatus, message string) {
	if job == nil {
		return
	}

	job.mu.Lock()
	job.Results.Contract.StageTransitions = append(job.Results.Contract.StageTransitions, DiscoveryStageTransition{
		Stage:     stage,
		Status:    status,
		Timestamp: time.Now(),
		Message:   message,
	})
	job.mu.Unlock()
}

func stageCompleted(transitions []DiscoveryStageTransition, stage DiscoveryStage) bool {
	for _, transition := range transitions {
		if transition.Stage == stage && transition.Status == DiscoveryStageStatusCompleted {
			return true
		}
	}
	return false
}

func topologyStageReady(transitions []DiscoveryStageTransition) bool {
	return stageCompleted(transitions, DiscoveryStageIdentity) &&
		stageCompleted(transitions, DiscoveryStageEnrich)
}

const (
	defaultConcurrencyMultiplier = 2 // Multiplier for target channel size
)
