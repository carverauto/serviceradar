/*
 * Copyright 2026 Carver Automation Corporation.
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
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

type executionSummaryStore struct {
	summary *models.SweepSummary
}

func (s *executionSummaryStore) SaveResult(context.Context, *models.Result) error { return nil }

func (s *executionSummaryStore) GetResults(context.Context, *models.ResultFilter) ([]models.Result, error) {
	return nil, nil
}

func (s *executionSummaryStore) GetSweepSummary(context.Context) (*models.SweepSummary, error) {
	if s.summary == nil {
		return &models.SweepSummary{}, nil
	}

	clone := *s.summary
	clone.Hosts = append([]models.HostResult(nil), s.summary.Hosts...)

	return &clone, nil
}

func (s *executionSummaryStore) PruneResults(context.Context, time.Duration) error { return nil }

func TestSweepExecutionIDBoundToCompletedSweep(t *testing.T) {
	store := &executionSummaryStore{summary: &models.SweepSummary{
		TotalHosts:     1,
		AvailableHosts: 1,
		Hosts:          []models.HostResult{{Host: "192.0.2.10", Available: true}},
	}}
	sweeper := &NetworkSweeper{
		logger: logger.NewTestLogger(),
		store:  store,
	}

	sweeper.runExecutionID = "exec-a"
	require.NoError(t, sweeper.completeSuccessfulSweep(context.Background(), time.Now().Add(-time.Second), false))

	sweeper.sweepInProgress = true
	sweeper.runExecutionID = "exec-b"
	inProgress, err := sweeper.GetStatus(context.Background())
	require.NoError(t, err)
	require.Equal(t, "exec-a", inProgress.ExecutionID)
	require.Equal(t, "192.0.2.10", inProgress.Hosts[0].Host)

	sweeper.sweepInProgress = false
	require.NoError(t, sweeper.completeSuccessfulSweep(context.Background(), time.Now().Add(-time.Second), false))
	completed, err := sweeper.GetStatus(context.Background())
	require.NoError(t, err)
	require.Equal(t, "exec-b", completed.ExecutionID)

	sweeper.runExecutionID = ""
	require.NoError(t, sweeper.completeSuccessfulSweep(context.Background(), time.Now().Add(-time.Second), false))
	local, err := sweeper.GetStatus(context.Background())
	require.NoError(t, err)
	require.Empty(t, local.ExecutionID)
}

func TestRunOnceStoppedDoesNotSucceed(t *testing.T) {
	sweeper := &NetworkSweeper{
		logger:          logger.NewTestLogger(),
		done:            make(chan struct{}),
		lastExecutionID: "previous",
	}
	close(sweeper.done)

	err := sweeper.RunOnceWithExecution(context.Background(), "exec-new")
	require.ErrorIs(t, err, errSweeperStopped)
	require.Equal(t, "previous", sweeper.lastExecutionID)
}

func TestExecutionCheckRunsAfterSweeperLock(t *testing.T) {
	sweeper := &NetworkSweeper{}
	sweeper.runMu.Lock()
	checked := make(chan struct{})
	ctx := WithExecutionCheck(context.Background(), func() error {
		close(checked)
		return context.Canceled
	})
	done := make(chan error, 1)
	go func() { done <- sweeper.runSweepWithExecution(ctx, "queued") }()
	select {
	case <-checked:
		t.Error("execution check ran before owning sweep lock")
	case <-time.After(20 * time.Millisecond):
	}
	sweeper.runMu.Unlock()
	require.ErrorIs(t, <-done, context.Canceled)
	<-checked
}

func TestLeasedSweepEnumeratesSignedCIDREndpoints(t *testing.T) {
	s := &NetworkSweeper{config: &models.Config{Networks: []string{"192.0.2.0/30"}, SweepModes: []models.SweepMode{models.ModeICMP}}, logger: logger.NewTestLogger()}
	legacy, err := s.generateTargets()
	require.NoError(t, err)
	require.Len(t, legacy, 2)
	s.resultObserver = func(*models.Result) error { return nil }
	targets, err := s.generateTargets()
	require.NoError(t, err)
	require.Len(t, targets, 4)
	require.Equal(t, "192.0.2.0", targets[0].Host)
	require.Equal(t, "192.0.2.3", targets[3].Host)
	var batched []models.Target
	require.NoError(t, s.generateTargetsBatched(func(target models.Target) error { batched = append(batched, target); return nil }))
	require.Len(t, batched, 4)
}
