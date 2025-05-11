/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package netflow

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

// Consumer handles pulling messages from JetStream.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
	consumer     jetstream.Consumer
}

// NewConsumer creates or retrieves a JetStream pull consumer.
func NewConsumer(ctx context.Context, js jetstream.JetStream, streamName, consumerName string) (*Consumer, error) {
	log.Printf("Creating/getting pull consumer: stream=%s, consumer=%s", streamName, consumerName)

	consumer, err := js.Consumer(ctx, streamName, consumerName)
	if err != nil {
		cfg := jetstream.ConsumerConfig{
			Durable:       consumerName, // Use the provided consumerName as durable name
			AckPolicy:     jetstream.AckExplicitPolicy,
			AckWait:       30 * time.Second,
			MaxDeliver:    3,
			MaxAckPending: 1000,
			// No DeliverSubject or DeliverGroup needed for pull consumers
		}
		consumer, err = js.CreateConsumer(ctx, streamName, cfg)
		if err != nil {
			log.Printf("Failed to create consumer: stream=%s, consumer=%s, err=%v", streamName, consumerName, err)
			return nil, fmt.Errorf("failed to create consumer: %w", err)
		}
	}

	log.Printf("Successfully got/created consumer: stream=%s, consumer=%s", streamName, consumerName)
	return &Consumer{
		js:           js,
		streamName:   streamName,
		consumerName: consumerName,
		consumer:     consumer,
	}, nil
}

const (
	defaultMaxPullMessages = 10
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
)

// handleMessage processes a single message with the provided processor.
func (c *Consumer) handleMessage(ctx context.Context, msg jetstream.Msg, processor *Processor) {
	metadata, _ := msg.Metadata()
	log.Printf("Processing message: subject=%s, seq=%d, tries=%d", msg.Subject(), metadata.Sequence.Stream, metadata.NumDelivered)

	processErr := processor.Process(ctx, msg)
	if processErr != nil {
		log.Printf("Failed to process message: %v", processErr)

		// Check if max retries reached
		if metadata.NumDelivered >= defaultMaxRetries {
			log.Printf("Max retries reached, acknowledging message")
			if ackErr := msg.Ack(); ackErr != nil {
				log.Printf("Failed to Ack message: %v", ackErr)
			}
			return
		}

		// Negative acknowledge to retry
		if nakErr := msg.Nak(); nakErr != nil {
			log.Printf("Failed to Nak message: %v", nakErr)
		}
		return
	}

	// Successfully processed, acknowledge the message
	if ackErr := msg.Ack(); ackErr != nil {
		log.Printf("Failed to Ack message: %v", ackErr)
	}
}

// ProcessMessages fetches messages from the pull consumer and processes them.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	log.Printf("Starting pull consumer for stream %s, consumer %s", c.streamName, c.consumerName)

	for {
		select {
		case <-ctx.Done():
			log.Println("Stopping message processing due to context cancellation")
			return
		default:
			// Fetch a batch of messages
			msgs, err := c.consumer.Fetch(defaultMaxPullMessages, jetstream.FetchMaxWait(defaultPullExpiry))
			if err != nil {
				log.Printf("Failed to fetch messages: %v", err)
				time.Sleep(1 * time.Second) // Backoff before retrying
				continue
			}

			// Process each message in the batch
			for msg := range msgs.Messages() {
				c.handleMessage(ctx, msg, processor)
			}

			// Check for fetch errors (e.g., timeout)
			if fetchErr := msgs.Error(); fetchErr != nil {
				log.Printf("Fetch error: %v", fetchErr)
			}
		}
	}
}
