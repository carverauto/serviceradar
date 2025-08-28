package dbeventwriter

import (
	"context"
	"fmt"
	"time"

	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// Consumer wraps a JetStream pull consumer.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
	consumer     jetstream.Consumer
	logger       logger.Logger
}

// NewConsumer creates or retrieves a pull consumer for the given stream.
func NewConsumer(
	ctx context.Context,
	js jetstream.JetStream,
	streamName, consumerName string,
	subjects []string,
	log logger.Logger) (*Consumer, error) {
	log.Debug().
		Str("stream_name", streamName).
		Str("consumer_name", consumerName).
		Strs("subjects", subjects).
		Msg("Creating/getting pull consumer")

	cfg := jetstream.ConsumerConfig{
		Durable:       consumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       30 * time.Second,
		MaxDeliver:    3,
		MaxAckPending: 1000,
	}

	if len(subjects) == 1 {
		cfg.FilterSubject = subjects[0]
	} else if len(subjects) > 1 {
		cfg.FilterSubjects = subjects
	}

	// Always create or update the consumer to ensure it has the correct filter subjects
	consumer, err := js.CreateOrUpdateConsumer(ctx, streamName, cfg)
	if err != nil {
		log.Error().
			Err(err).
			Str("stream_name", streamName).
			Str("consumer_name", consumerName).
			Strs("subjects", subjects).
			Msg("Failed to create or update consumer")

		return nil, fmt.Errorf("failed to create or update consumer: %w", err)
	}

	log.Debug().Msg("Pull consumer created or retrieved successfully")

	return &Consumer{js: js, streamName: streamName, consumerName: consumerName, consumer: consumer, logger: log}, nil
}

const (
	defaultMaxPullMessages = 50
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
)

func (c *Consumer) handleBatch(ctx context.Context, msgs []jetstream.Msg, processor *Processor) {
	processed, err := processor.ProcessBatch(ctx, msgs)
	if err != nil {
		c.logger.Error().Err(err).Msg("Failed to process message batch")

		for _, msg := range processed {
			metadata, _ := msg.Metadata()

			if metadata.NumDelivered >= defaultMaxRetries {
				_ = msg.Ack()
			} else {
				_ = msg.Nak()
			}
		}

		return
	}

	for _, msg := range processed {
		c.logger.Debug().
			Str("subject", msg.Subject()).
			Msg("Message processed successfully")

		_ = msg.Ack()
	}
}

// ProcessMessages continuously fetches and processes messages.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	c.logger.Info().
		Str("stream_name", c.streamName).
		Str("consumer_name", c.consumerName).
		Msg("Starting pull consumer")

	for {
		select {
		case <-ctx.Done():
			c.logger.Info().Msg("Stopping message processing due to context cancellation")
			return
		default:
			msgs, err := c.consumer.Fetch(defaultMaxPullMessages, jetstream.FetchMaxWait(defaultPullExpiry))
			if err != nil {
				c.logger.Error().Err(err).Msg("Failed to fetch messages")
				time.Sleep(time.Second)

				continue
			}

			c.logger.Debug().
				Int("message_count", len(msgs.Messages())).
				Str("stream_name", c.streamName).
				Str("consumer_name", c.consumerName).
				Msg("Fetched messages")

			batch := make([]jetstream.Msg, 0, defaultMaxPullMessages)
			for msg := range msgs.Messages() {
				batch = append(batch, msg)
			}

			if len(batch) > 0 {
				c.logger.Debug().
					Int("batch_size", len(batch)).
					Msg("Processing batch of messages")

				c.handleBatch(ctx, batch, processor)
			}

			if fetchErr := msgs.Error(); fetchErr != nil {
				c.logger.Error().Err(fetchErr).Msg("Fetch error")
			}
		}
	}
}
