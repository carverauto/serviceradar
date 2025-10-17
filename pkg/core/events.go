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

package core

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/cenkalti/backoff/v5"
	"github.com/nats-io/nats.go"
)

// initializeEventPublisher sets up the NATS connection and event publisher using natsutil
func (s *Server) initializeEventPublisher(ctx context.Context, config *models.CoreServiceConfig) error {
	// Skip if events are not configured or disabled
	if config.Events == nil || !config.Events.Enabled {
		s.setEventPublisher(nil, nil)
		s.logger.Info().Msg("Events not configured or disabled, event publishing disabled")
		return nil
	}

	// Skip if NATS is not configured
	if config.NATS == nil {
		s.setEventPublisher(nil, nil)
		s.logger.Info().Msg("NATS not configured, event publishing disabled")
		return nil
	}

	if err := config.NATS.Validate(); err != nil {
		return fmt.Errorf("invalid NATS configuration: %w", err)
	}

	if err := config.Events.Validate(); err != nil {
		return fmt.Errorf("invalid events configuration: %w", err)
	}

	// Use natsutil to create the connection with NATS-specific security config
	opts := []nats.Option{
		nats.MaxReconnects(-1),
		nats.RetryOnFailedConnect(true),
		nats.ReconnectWait(2 * time.Second),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			event := s.logger.Warn().Str("component", "nats.events")
			if err != nil {
				event = event.Err(err)
			}
			event.Msg("NATS events publisher disconnected")
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			s.logger.Info().
				Str("component", "nats.events").
				Str("url", nc.ConnectedUrl()).
				Msg("NATS events publisher reconnected")
		}),
		nats.ClosedHandler(func(_ *nats.Conn) {
			s.logger.Error().
				Str("component", "nats.events").
				Msg("NATS events publisher connection closed")
			s.scheduleEventPublisherReinit("closed_handler")
		}),
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			s.logger.Error().
				Err(err).
				Str("component", "nats.events").
				Msg("NATS events publisher error")
		}),
	}

	nc, err := natsutil.ConnectWithSecurity(ctx, config.NATS.URL, config.NATS.Security, opts...)
	if err != nil {
		return fmt.Errorf("failed to connect to NATS: %w", err)
	}

	// Create the event publisher - use domain-specific function only if domain is configured
	var publisher *natsutil.EventPublisher

	if config.NATS.Domain != "" {
		publisher, err = natsutil.CreateEventPublisherWithDomain(ctx, nc, config.NATS.Domain, config.Events.StreamName, config.Events.Subjects)
	} else {
		publisher, err = natsutil.CreateEventPublisher(ctx, nc, config.Events.StreamName, config.Events.Subjects)
	}

	if err != nil {
		nc.Close()
		return fmt.Errorf("failed to create event publisher: %w", err)
	}

	s.setEventPublisher(publisher, nc)

	s.logger.Info().
		Str("stream_name", config.Events.StreamName).
		Msg("NATS event publisher initialized")

	return nil
}

func (s *Server) setEventPublisher(publisher *natsutil.EventPublisher, conn *nats.Conn) {
	s.mu.Lock()
	oldConn := s.natsConn
	s.eventPublisher = publisher
	s.natsConn = conn
	s.mu.Unlock()

	if oldConn != nil && oldConn != conn {
		oldConn.Close()
	}
}

func (s *Server) scheduleEventPublisherReinit(reason string) {
	s.natsReconnectMu.Lock()
	if s.natsReconnectActive {
		s.natsReconnectMu.Unlock()
		s.logger.Debug().
			Str("component", "nats.events").
			Str("reason", reason).
			Msg("NATS event publisher reinitialization already in progress")
		return
	}
	s.natsReconnectActive = true
	s.natsReconnectMu.Unlock()

	go s.reinitializeEventPublisher(reason)
}

func (s *Server) reinitializeEventPublisher(reason string) {
	defer func() {
		s.natsReconnectMu.Lock()
		s.natsReconnectActive = false
		s.natsReconnectMu.Unlock()
	}()

	if s.config == nil || s.config.Events == nil || !s.config.Events.Enabled {
		return
	}

	backoffPolicy := backoff.NewExponentialBackOff()
	backoffPolicy.InitialInterval = 1 * time.Second
	backoffPolicy.MaxInterval = 30 * time.Second
	backoffPolicy.Reset()

	for {
		select {
		case <-s.ShutdownChan:
			s.logger.Info().
				Str("component", "nats.events").
				Str("reason", reason).
				Msg("Shutdown signal received, aborting NATS event publisher reinitialization")
			return
		default:
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		err := s.initializeEventPublisher(ctx, s.config)
		cancel()

		if err == nil {
			s.logger.Info().
				Str("component", "nats.events").
				Str("reason", reason).
				Msg("NATS event publisher reinitialized successfully")
			return
		}

		delay := backoffPolicy.NextBackOff()
		s.logger.Warn().
			Err(err).
			Dur("backoff", delay).
			Str("component", "nats.events").
			Str("reason", reason).
			Msg("Failed to reinitialize NATS event publisher, retrying")

		select {
		case <-time.After(delay):
		case <-s.ShutdownChan:
			s.logger.Info().
				Str("component", "nats.events").
				Str("reason", reason).
				Msg("Shutdown signal received during backoff, aborting NATS event publisher reinitialization")
			return
		}
	}
}

func (s *Server) handleEventPublishError(err error, reason string) {
	if err == nil {
		return
	}

	if errors.Is(err, nats.ErrConnectionClosed) ||
		errors.Is(err, nats.ErrNoServers) ||
		errors.Is(err, nats.ErrInvalidConnection) {
		s.scheduleEventPublisherReinit(reason)
	}
}
