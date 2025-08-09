// WebSocket client for testing streaming API
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// StreamMessage represents a message received from the WebSocket
type StreamMessage struct {
	Type      string                 `json:"type"`
	Data      map[string]interface{} `json:"data,omitempty"`
	Error     string                 `json:"error,omitempty"`
	Timestamp time.Time              `json:"timestamp"`
}

func main() {
	// Parse command line flags
	var (
		host    = flag.String("host", "localhost:8090", "API server host:port")
		apiKey  = flag.String("api-key", "", "API key for authentication")
		query   = flag.String("query", "SHOW logs LIMIT 10", "SRQL query to stream")
		secure  = flag.Bool("secure", false, "Use WSS instead of WS")
		envFile = flag.String("env-file", "/etc/serviceradar/api.env", "Path to API environment file")
	)
	flag.Parse()

	// Get API key from environment if not provided
	if *apiKey == "" {
		*apiKey = os.Getenv("API_KEY")
		
		// If still not set, try to read from env file
		if *apiKey == "" && *envFile != "" {
			*apiKey = readAPIKeyFromEnvFile(*envFile)
		}
		
		if *apiKey == "" {
			log.Fatal("API key required: provide via -api-key flag, API_KEY environment variable, or in " + *envFile)
		}
	}

	// Build WebSocket URL
	scheme := "ws"
	if *secure {
		scheme = "wss"
	}

	u := url.URL{
		Scheme:   scheme,
		Host:     *host,
		Path:     "/api/stream",
		RawQuery: url.Values{"query": {*query}}.Encode(),
	}

	log.Printf("Connecting to %s", u.String())

	// Set up headers with authentication
	headers := make(map[string][]string)
	headers["X-API-Key"] = []string{*apiKey}

	// Connect to WebSocket
	conn, resp, err := websocket.DefaultDialer.Dial(u.String(), headers)
	if err != nil {
		if resp != nil {
			log.Printf("HTTP response status: %s", resp.Status)
		}
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()

	log.Printf("Connected successfully. Streaming query: %s", *query)

	// Handle graceful shutdown
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, syscall.SIGINT, syscall.SIGTERM)

	// Channel for receiving messages
	messages := make(chan StreamMessage, 100)
	done := make(chan struct{})

	// Start goroutine to read messages
	go func() {
		defer close(done)
		for {
			var msg StreamMessage
			err := conn.ReadJSON(&msg)
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
					log.Printf("WebSocket error: %v", err)
				}
				return
			}
			messages <- msg
		}
	}()

	// Statistics
	var (
		rowCount    int
		errorCount  int
		startTime   = time.Now()
	)

	// Main event loop
	for {
		select {
		case msg := <-messages:
			switch msg.Type {
			case "data":
				rowCount++
				// Pretty print the data
				data, _ := json.MarshalIndent(msg.Data, "", "  ")
				fmt.Printf("\n=== Row %d (%.3fs) ===\n%s\n", 
					rowCount, time.Since(startTime).Seconds(), string(data))

			case "error":
				errorCount++
				log.Printf("ERROR: %s", msg.Error)

			case "complete":
				log.Printf("\n✅ Stream completed successfully")
				log.Printf("   Total rows: %d", rowCount)
				log.Printf("   Total errors: %d", errorCount)
				log.Printf("   Duration: %s", time.Since(startTime))
				return

			case "ping":
				log.Printf("Received ping at %s", msg.Timestamp.Format(time.RFC3339))

			default:
				log.Printf("Unknown message type: %s", msg.Type)
			}

		case <-interrupt:
			log.Println("\nReceived interrupt signal, closing connection...")

			// Cleanly close the connection
			err := conn.WriteMessage(websocket.CloseMessage, 
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
			if err != nil {
				log.Printf("Error sending close message: %v", err)
			}

			select {
			case <-done:
			case <-time.After(time.Second):
			}
			return

		case <-done:
			return
		}
	}
}

// readAPIKeyFromEnvFile reads the API_KEY from an environment file
func readAPIKeyFromEnvFile(envFile string) string {
	file, err := os.Open(envFile)
	if err != nil {
		log.Printf("Failed to open env file %s: %v", envFile, err)
		return ""
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		
		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		
		// Look for API_KEY=value
		if strings.HasPrefix(line, "API_KEY=") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				return strings.TrimSpace(parts[1])
			}
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Error reading env file %s: %v", envFile, err)
	}

	return ""
}