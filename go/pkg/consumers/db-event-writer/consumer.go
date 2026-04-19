package dbeventwriter

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// Consumer wraps a JetStream pull consumer.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
	consumer     pullConsumer
	logger       logger.Logger
}

type pullConsumer interface {
	Fetch(batch int, opts ...jetstream.FetchOpt) (jetstream.MessageBatch, error)
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

	consumer, err := ensurePullConsumer(ctx, js, streamName, consumerName, subjects, cfg, log)
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

func ensurePullConsumer(
	ctx context.Context,
	js jetstream.JetStream,
	streamName, consumerName string,
	subjects []string,
	cfg jetstream.ConsumerConfig,
	log logger.Logger,
) (jetstream.Consumer, error) {
	existing, err := js.Consumer(ctx, streamName, consumerName)
	switch {
	case err == nil:
		info, infoErr := existing.Info(ctx)
		if infoErr == nil && consumerConfigMatches(info.Config, cfg, subjects) {
			return existing, nil
		}

		log.Warn().
			Str("stream_name", streamName).
			Str("consumer_name", consumerName).
			Strs("subjects", subjects).
			Msg("Existing consumer config changed; recreating durable pull consumer")

		if deleteErr := js.DeleteConsumer(ctx, streamName, consumerName); deleteErr != nil &&
			!errors.Is(deleteErr, jetstream.ErrConsumerNotFound) {
			return nil, fmt.Errorf("delete mismatched consumer %s: %w", consumerName, deleteErr)
		}
	case !errors.Is(err, jetstream.ErrConsumerNotFound):
		log.Warn().
			Err(err).
			Str("stream_name", streamName).
			Str("consumer_name", consumerName).
			Msg("Failed to inspect existing consumer; retrying create-or-get path")
	}

	return createOrGetConsumer(ctx, js, streamName, consumerName, cfg, subjects, log)
}

func createOrGetConsumer(
	ctx context.Context,
	js jetstream.JetStream,
	streamName, consumerName string,
	cfg jetstream.ConsumerConfig,
	subjects []string,
	log logger.Logger,
) (jetstream.Consumer, error) {
	consumer, err := js.CreateOrUpdateConsumer(ctx, streamName, cfg)
	if err == nil {
		return consumer, nil
	}

	log.Warn().
		Err(err).
		Str("stream_name", streamName).
		Str("consumer_name", consumerName).
		Msg("CreateOrUpdateConsumer failed; retrying with existing durable lookup")

	existing, getErr := js.Consumer(ctx, streamName, consumerName)
	if getErr != nil {
		return nil, fmt.Errorf("create/update failed: %w; get failed: %w", err, getErr)
	}

	info, infoErr := existing.Info(ctx)
	if infoErr != nil {
		return nil, fmt.Errorf("create/update failed: %w; info failed: %w", err, infoErr)
	}

	if !consumerConfigMatches(info.Config, cfg, subjects) {
		return nil, fmt.Errorf("create/update failed: %w; existing consumer %s has mismatched config", err, consumerName)
	}

	return existing, nil
}

func consumerConfigMatches(current, desired jetstream.ConsumerConfig, subjects []string) bool {
	if current.Durable != desired.Durable {
		return false
	}

	if current.AckPolicy != desired.AckPolicy ||
		current.AckWait != desired.AckWait ||
		current.MaxDeliver != desired.MaxDeliver ||
		current.MaxAckPending != desired.MaxAckPending {
		return false
	}

	return normalizedConsumerSubjects(current) == normalizedSubjects(subjects)
}

func normalizedConsumerSubjects(cfg jetstream.ConsumerConfig) string {
	switch {
	case cfg.FilterSubject != "":
		return normalizedSubjects([]string{cfg.FilterSubject})
	case len(cfg.FilterSubjects) > 0:
		return normalizedSubjects(cfg.FilterSubjects)
	default:
		return normalizedSubjects(nil)
	}
}

func normalizedSubjects(subjects []string) string {
	if len(subjects) == 0 {
		return ""
	}

	normalized := make([]string, 0, len(subjects))
	for _, subject := range subjects {
		if subject == "" {
			continue
		}
		normalized = append(normalized, subject)
	}

	sort.Strings(normalized)
	return fmt.Sprintf("%q", normalized)
}

const (
	defaultMaxPullMessages = 50
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
	reconnectDelay         = 5 * time.Second
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
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) error {
	c.logger.Info().
		Str("stream_name", c.streamName).
		Str("consumer_name", c.consumerName).
		Msg("Starting pull consumer")

	for {
		select {
		case <-ctx.Done():
			c.logger.Info().Msg("Stopping message processing due to context cancellation")
			return ctx.Err()
		default:
			msgs, err := c.consumer.Fetch(defaultMaxPullMessages, jetstream.FetchMaxWait(defaultPullExpiry))
			if err != nil {
				if isContextError(err) {
					return err
				}

				if isFatalFetchError(err) {
					return err
				}

				c.logger.Error().Err(err).Msg("Failed to fetch messages")
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(reconnectDelay):
				}

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
				if isContextError(fetchErr) {
					return fetchErr
				}

				if isFatalFetchError(fetchErr) {
					return fetchErr
				}

				c.logger.Error().Err(fetchErr).Msg("Fetch error")
			}
		}
	}
}

func isContextError(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

func isFatalFetchError(err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, nats.ErrConnectionClosed),
		errors.Is(err, nats.ErrNoServers),
		errors.Is(err, nats.ErrNoResponders),
		errors.Is(err, jetstream.ErrConsumerDeleted),
		errors.Is(err, jetstream.ErrConsumerNotFound),
		errors.Is(err, jetstream.ErrJetStreamNotEnabled),
		errors.Is(err, jetstream.ErrStreamNotFound):
		return true
	default:
		return false
	}
}
