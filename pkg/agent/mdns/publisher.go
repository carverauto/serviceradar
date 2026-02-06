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

package mdns

import (
	"context"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/natsutil"
)

// Publisher reads protobuf-encoded mDNS records from a channel and publishes
// them to NATS JetStream.
type Publisher struct {
	config *Config
	ch     <-chan []byte
	nc     *nats.Conn
	js     jetstream.JetStream
	logger logger.Logger
}

// NewPublisher creates a new NATS JetStream publisher.
func NewPublisher(config *Config, ch <-chan []byte, log logger.Logger) *Publisher {
	return &Publisher{
		config: config,
		ch:     ch,
		logger: log,
	}
}

// Connect establishes the NATS connection with exponential backoff retry.
func (p *Publisher) Connect(ctx context.Context) error {
	var (
		attempt        uint32
		backoff        = 500 * time.Millisecond
		maxBackoff     = 30 * time.Second
		maxAttempts    uint32 = 60
	)

	for {
		attempt++
		err := p.connectOnce(ctx)
		if err == nil {
			return nil
		}

		if attempt >= maxAttempts {
			return fmt.Errorf("%w: %v (after %d attempts)", ErrNATSConnection, err, maxAttempts)
		}

		p.logger.Warn().
			Err(err).
			Uint32("attempt", attempt).
			Dur("backoff", backoff).
			Msg("NATS connection attempt failed, retrying")

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (p *Publisher) connectOnce(ctx context.Context) error {
	var opts []nats.Option

	if p.config.NATSCredsFile != "" {
		opts = append(opts, nats.UserCredentials(p.config.NATSCredsFile))
	}

	nc, err := natsutil.ConnectWithSecurity(ctx, p.config.NATSUrl, p.config.Security, opts...)
	if err != nil {
		return err
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return fmt.Errorf("failed to create JetStream context: %w", err)
	}

	// Ensure stream exists
	if err := p.ensureStream(ctx, js); err != nil {
		nc.Close()
		return err
	}

	p.nc = nc
	p.js = js

	p.logger.Info().
		Str("url", p.config.NATSUrl).
		Str("stream", p.config.StreamName).
		Msg("Connected to NATS and ensured stream exists")

	return nil
}

func (p *Publisher) ensureStream(ctx context.Context, js jetstream.JetStream) error {
	requiredSubjects := p.config.StreamSubjectsResolved()

	stream, err := js.Stream(ctx, p.config.StreamName)
	if err != nil {
		// Stream doesn't exist, create it
		_, createErr := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
			Name:     p.config.StreamName,
			Subjects: requiredSubjects,
			Storage:  jetstream.FileStorage,
			MaxBytes: p.config.StreamMaxBytes,
			MaxAge:   24 * time.Hour,
		})
		return createErr
	}

	// Stream exists, check if subjects need updating
	info, err := stream.Info(ctx)
	if err != nil {
		return fmt.Errorf("failed to get stream info: %w", err)
	}

	needsUpdate := false
	currentSubjects := info.Config.Subjects
	for _, required := range requiredSubjects {
		found := false
		for _, existing := range currentSubjects {
			if existing == required {
				found = true
				break
			}
		}
		if !found {
			currentSubjects = append(currentSubjects, required)
			needsUpdate = true
		}
	}

	if needsUpdate {
		cfg := info.Config
		cfg.Subjects = currentSubjects
		_, err = js.CreateOrUpdateStream(ctx, cfg)
		if err != nil {
			return fmt.Errorf("failed to update stream subjects: %w", err)
		}
	}

	return nil
}

// Run reads from the channel and publishes batches to NATS.
// Blocks until the channel is closed or context is cancelled.
func (p *Publisher) Run(ctx context.Context) {
	batch := make([][]byte, 0, p.config.BatchSize)
	timeout := time.Duration(p.config.PublishTimeoutMs) * time.Millisecond

	p.logger.Info().
		Str("subject", p.config.Subject).
		Msg("mDNS publisher started")

	for {
		select {
		case <-ctx.Done():
			if len(batch) > 0 {
				p.publishBatch(ctx, batch, timeout)
			}
			return
		case msg, ok := <-p.ch:
			if !ok {
				if len(batch) > 0 {
					p.publishBatch(ctx, batch, timeout)
				}
				p.logger.Info().Msg("mDNS publisher channel closed, shutting down")
				return
			}

			batch = append(batch, msg)

			// Drain any immediately-available messages to build a batch
			draining := true
			for draining && len(batch) < p.config.BatchSize {
				select {
				case msg, ok := <-p.ch:
					if !ok {
						draining = false
					} else {
						batch = append(batch, msg)
					}
				default:
					draining = false
				}
			}

			if len(batch) > 0 {
				p.publishBatch(ctx, batch, timeout)
				batch = batch[:0]
			}
		}
	}
}

func (p *Publisher) publishBatch(ctx context.Context, batch [][]byte, timeout time.Duration) {
	pubCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for _, msg := range batch {
		_, err := p.js.Publish(pubCtx, p.config.Subject, msg)
		if err != nil {
			p.logger.Error().Err(err).Msg("Failed to publish mDNS record to NATS")
		}
	}
}

// Close closes the NATS connection.
func (p *Publisher) Close() {
	if p.nc != nil {
		p.nc.Close()
	}
}
