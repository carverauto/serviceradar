package netflow

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

// Consumer manages the NATS JetStream pull consumer.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
}

// NewConsumer creates or retrieves a durable pull consumer.
func NewConsumer(ctx context.Context, js jetstream.JetStream, streamName, consumerName string) (*Consumer, error) {
	// Check if consumer exists
	_, err := js.Consumer(ctx, streamName, consumerName)
	if err == nil {
		log.Printf("Using existing consumer %s for stream %s", consumerName, streamName)

		return &Consumer{
			js:           js,
			streamName:   streamName,
			consumerName: consumerName,
		}, nil
	}

	// Return error if it's not a "consumer not found" error
	if !errors.Is(err, jetstream.ErrConsumerNotFound) {
		return nil, err
	}

	// Create consumer
	_, err = js.CreateOrUpdateConsumer(ctx, streamName, jetstream.ConsumerConfig{
		Durable:       consumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		Description:   "NetFlow message consumer",
		MaxDeliver:    3,
		AckWait:       30 * time.Second,
	})
	if err != nil {
		return nil, err
	}

	log.Printf("Created consumer %s for stream %s", consumerName, streamName)

	return &Consumer{
		js:           js,
		streamName:   streamName,
		consumerName: consumerName,
	}, nil
}

const (
	defaultMaxPullMessages = 10
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
)

// handleMessage processes a single message with the provided processor.
func (*Consumer) handleMessage(ctx context.Context, msg jetstream.Msg, processor *Processor) {
	metadata, _ := msg.Metadata()
	log.Printf("Processing message: subject=%s, seq=%d, tries=%d", msg.Subject(), metadata.Sequence.Stream, metadata.NumDelivered)

	processErr := processor.Process(ctx, msg)
	if processErr != nil {
		log.Printf("Failed to process message: %v", processErr)

		// Check if max retries reached
		if metadata.NumDelivered > defaultMaxRetries { // Max 3 retries
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

// ProcessMessages fetches and processes messages using the provided processor.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	cons, err := c.js.Consumer(ctx, c.streamName, c.consumerName)
	if err != nil {
		log.Printf("Failed to get consumer: %v", err)

		return
	}

	consCtx, err := cons.Consume(func(msg jetstream.Msg) {
		c.handleMessage(ctx, msg, processor)
	}, jetstream.PullMaxMessages(defaultMaxPullMessages), jetstream.PullExpiry(defaultPullExpiry))
	if err != nil {
		log.Printf("Failed to start consumer: %v", err)

		return
	}
	defer consCtx.Stop()

	<-ctx.Done()

	log.Println("Stopping message processing due to context cancellation")
}
