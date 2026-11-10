// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// edgeSourceSessions owns the finite lane workers' current sessions. Freeze
// first excludes new sessions for the source, cancels its in-flight stream, and
// joins it. Successful freeze publishes the durable source hold before releasing
// the exclusion; failed freeze retains source bytes for retry.
type edgeSourceSessions struct {
	mu        sync.Mutex
	active    map[string]*edgeSourceSession
	suspended map[string]bool
}
type edgeSourceSession struct {
	cancel context.CancelFunc
	done   chan struct{}
}

func (s *edgeSourceSessions) begin(ctx context.Context, g *spool.Generation) (context.Context, func(), error) {
	key := string(g.Identity().SpoolID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.suspended[key] || s.active[key] != nil {
		return nil, nil, agent.ErrRecoveryPending
	}
	if s.active == nil {
		s.active = make(map[string]*edgeSourceSession)
	}
	sessionCtx, cancel := context.WithCancel(ctx)
	session := &edgeSourceSession{cancel: cancel, done: make(chan struct{})}
	s.active[key] = session
	finish := func() { cancel(); s.mu.Lock(); delete(s.active, key); close(session.done); s.mu.Unlock() }
	return sessionCtx, finish, nil
}

func (s *edgeSourceSessions) suspend(ctx context.Context, g *spool.Generation) (func(), error) {
	key := string(g.Identity().SpoolID)
	s.mu.Lock()
	if s.suspended == nil {
		s.suspended = make(map[string]bool)
	}
	s.suspended[key] = true
	session := s.active[key]
	s.mu.Unlock()
	resume := func() { s.mu.Lock(); delete(s.suspended, key); s.mu.Unlock() }
	if session != nil {
		session.cancel()
		select {
		case <-session.done:
		case <-ctx.Done():
			resume()
			return nil, ctx.Err()
		}
	}
	return resume, nil
}

func pollEdgeRecovery(ctx context.Context, c *agent.RecoveryCoordinator, log logger.Logger) {
	timer := time.NewTicker(100 * time.Millisecond)
	defer timer.Stop()
	var lastLog time.Time
	var lastPhase string
	var retryAfter time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		if time.Now().Before(retryAfter) {
			continue
		}
		steps := 1
		if !c.Ready() {
			steps = spool.MaxGenerationPage
		}
		for range steps {
			stepCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
			phase, err := c.Step(stepCtx)
			cancel()
			if err != nil {
				// Retained consumer waits and unavailable peers must not poll at
				// the local phase-advance frequency during a prolonged outage.
				retryAfter = time.Now().Add(5 * time.Second)
				if phase != lastPhase || time.Since(lastLog) >= 30*time.Second {
					log.Warn().Err(err).Str("phase", phase).Hex("recovery_id", c.OperationID()).Msg("Edge recovery remains pending")
					lastLog, lastPhase = time.Now(), phase
				}
				break
			}
			if phase == "completed" {
				log.Info().Msg("Edge recovery completed and storage reclaimed")
			}
		}
	}
}
