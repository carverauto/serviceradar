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
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/natsutil"
)

// initializeEventPublisher sets up the NATS connection and event publisher using natsutil
func (s *Server) initializeEventPublisher(ctx context.Context, config *models.DBConfig) error {
	// Skip if events are not configured or disabled
	if config.Events == nil || !config.Events.Enabled {
		log.Printf("Events not configured or disabled, event publishing disabled")
		return nil
	}

	// Skip if NATS is not configured
	if config.NATS == nil {
		log.Printf("NATS not configured, event publishing disabled")
		return nil
	}

	if err := config.NATS.Validate(); err != nil {
		return fmt.Errorf("invalid NATS configuration: %w", err)
	}

	if err := config.Events.Validate(); err != nil {
		return fmt.Errorf("invalid events configuration: %w", err)
	}

	// Use natsutil to create the connection with NATS-specific security config
	nc, err := natsutil.ConnectWithSecurity(ctx, config.NATS.URL, config.NATS.Security)
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

	s.eventPublisher = publisher
	s.natsConn = nc

	log.Printf("NATS event publisher initialized for stream: %s", config.Events.StreamName)

	return nil
}
