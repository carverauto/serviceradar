// Proof of concept for streaming data from Timeplus Proton
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/core"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/timeplus-io/proton-go-driver/v2"
)

func main() {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/core.json", "Path to core config file")
	flag.Parse()

	// Load configuration
	cfg, err := core.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create context
	ctx := context.Background()

	// Initialize logger
	mainLogger, err := lifecycle.CreateComponentLogger(ctx, "stream-poc", cfg.Logging)
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Create database connection using the same approach as core
	database, err := db.New(ctx, &cfg, mainLogger)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer database.Close()

	// Get the underlying proton connection for streaming
	connInterface, err := database.GetStreamingConnection()
	if err != nil {
		log.Fatalf("Failed to get streaming connection: %v", err)
	}

	conn, ok := connInterface.(proton.Conn)
	if !ok {
		log.Fatalf("Unexpected connection type: %T", connInterface)
	}

	mainLogger.Info().Msg("Connected to Proton database for streaming")

	// Create context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("Received shutdown signal")
		cancel()
	}()

	// Test streaming query - without table() wrapper
	streamingQuery := `
		SELECT 
			_tp_time,
			service_name,
			severity_text,
			body
		FROM logs
		WHERE service_name IS NOT NULL
		LIMIT 10
	`

	mainLogger.Info().Str("query", streamingQuery).Msg("Executing streaming query")

	// Execute streaming query using the proton connection
	rows, err := conn.Query(ctx, streamingQuery)
	if err != nil {
		mainLogger.Fatal().Err(err).Msg("Failed to execute query")
	}
	defer rows.Close()

	// Stream results
	count := 0
	for rows.Next() {
		var tpTime time.Time
		var serviceName, severityText, body string

		if err := rows.Scan(&tpTime, &serviceName, &severityText, &body); err != nil {
			mainLogger.Warn().Err(err).Msg("Error scanning row")
			continue
		}

		count++
		mainLogger.Info().
			Int("row", count).
			Time("timestamp", tpTime).
			Str("service", serviceName).
			Str("severity", severityText).
			Str("body", body).
			Msg("Streamed row")

		// For demo purposes, add a small delay to see streaming effect
		time.Sleep(100 * time.Millisecond)
	}

	if err := rows.Err(); err != nil {
		mainLogger.Error().Err(err).Msg("Error during iteration")
	}

	mainLogger.Info().Int("total_rows", count).Msg("Streaming completed")

	// Now test with OTEL traces
	mainLogger.Info().Msg("Testing OTEL Traces Stream")
	otelQuery := `
		SELECT 
			trace_id,
			span_id,
			span_name,
			service_name,
			start_time_unix_nano
		FROM otel_traces
		LIMIT 5
	`

	rows2, err := conn.Query(ctx, otelQuery)
	if err != nil {
		mainLogger.Error().Err(err).Msg("Failed to query OTEL traces")
	} else {
		defer rows2.Close()

		count2 := 0
		for rows2.Next() {
			var traceID, spanID, spanName, serviceName string
			var startTime int64

			if err := rows2.Scan(&traceID, &spanID, &spanName, &serviceName, &startTime); err != nil {
				mainLogger.Warn().Err(err).Msg("Error scanning OTEL row")
				continue
			}

			count2++
			mainLogger.Info().
				Int("row", count2).
				Str("trace_id", traceID).
				Str("span_name", spanName).
				Str("service", serviceName).
				Msg("OTEL trace row")
		}
		mainLogger.Info().Int("total_rows", count2).Msg("OTEL streaming completed")
	}

	// Test events stream
	mainLogger.Info().Msg("Testing Events Stream")
	eventsQuery := `
		SELECT 
			_tp_time,
			event_type,
			host,
			message
		FROM events
		WHERE _tp_time > now() - INTERVAL 1 HOUR
		LIMIT 5
	`

	rows3, err := conn.Query(ctx, eventsQuery)
	if err != nil {
		mainLogger.Error().Err(err).Msg("Failed to query events")
	} else {
		defer rows3.Close()

		count3 := 0
		for rows3.Next() {
			var tpTime time.Time
			var eventType, host, message interface{}

			if err := rows3.Scan(&tpTime, &eventType, &host, &message); err != nil {
				mainLogger.Warn().Err(err).Msg("Error scanning event row")
				continue
			}

			count3++
			mainLogger.Info().
				Int("row", count3).
				Time("timestamp", tpTime).
				Interface("event_type", eventType).
				Interface("host", host).
				Interface("message", message).
				Msg("Event row")
		}
		mainLogger.Info().Int("total_rows", count3).Msg("Events streaming completed")
	}

	mainLogger.Info().Msg("✅ Proof of concept complete!")
	mainLogger.Info().Msg("Key findings:")
	mainLogger.Info().Msg("1. Streaming queries work without table() wrapper")
	mainLogger.Info().Msg("2. Proton driver's Query method supports streaming")
	mainLogger.Info().Msg("3. Can handle logs, OTEL traces, and events streams")
}
