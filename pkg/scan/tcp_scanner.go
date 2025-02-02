// Package scan provides network scanning functionality
package scan

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	defaultCleanupInterval  = 30 * time.Second
	defaultMaxLifetime      = 10 * time.Minute
	defaultIdleTimeout      = 1 * time.Minute
	defaultReadDeadline     = 100 * time.Millisecond
	defaultDNSLookupTimeout = 200 * time.Millisecond
)

// connEntry represents a connection in the pool.
type connEntry struct {
	conn      net.Conn
	createdAt time.Time
	lastUsed  time.Time
}

// connectionPool manages a pool of reusable TCP connections with proper lifecycle management.
type connectionPool struct {
	mu            sync.RWMutex
	connections   map[string][]*connEntry
	maxIdle       int
	maxLifetime   time.Duration
	idleTimeout   time.Duration
	cleanupTicker *time.Ticker
	done          chan struct{}
}

// newConnectionPool creates a new connection pool with proper lifecycle management.
func newConnectionPool(maxIdle int, maxLifetime, idleTimeout time.Duration) *connectionPool {
	if maxLifetime == 0 {
		maxLifetime = defaultMaxLifetime
	}

	if idleTimeout == 0 {
		idleTimeout = defaultIdleTimeout
	}

	pool := &connectionPool{
		connections: make(map[string][]*connEntry),
		maxIdle:     maxIdle,
		maxLifetime: maxLifetime,
		idleTimeout: idleTimeout,
		done:        make(chan struct{}),
	}

	// Start the cleanup goroutine
	pool.startCleanup()

	return pool
}

// startCleanup starts a background goroutine to clean up stale connections.
func (p *connectionPool) startCleanup() {
	p.cleanupTicker = time.NewTicker(defaultCleanupInterval)

	go func() {
		for {
			select {
			case <-p.done:
				return
			case <-p.cleanupTicker.C:
				p.cleanup()
			}
		}
	}()
}

// cleanup removes stale connections from the pool.
func (p *connectionPool) cleanup() {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()

	for address, entries := range p.connections {
		valid := make([]*connEntry, 0, len(entries))

		for _, entry := range entries {
			// Check if the connection is too old or has been idle too long
			if now.Sub(entry.createdAt) > p.maxLifetime ||
				now.Sub(entry.lastUsed) > p.idleTimeout {
				if err := entry.conn.Close(); err != nil {
					log.Printf("Error closing stale connection: %v", err)
				}

				continue
			}

			valid = append(valid, entry)
		}

		if len(valid) == 0 {
			delete(p.connections, address)
		} else {
			p.connections[address] = valid
		}
	}
}

// get retrieves a connection from the pool or creates a new one.
func (p *connectionPool) get(ctx context.Context, dialer *net.Dialer, address string) (net.Conn, error) {
	// First try to get an existing connection
	if conn := p.getExisting(address); conn != nil {
		return conn, nil
	}

	// Create a new connection if none available
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, fmt.Errorf("failed to create connection: %w", err)
	}

	return conn, nil
}

// getExisting retrieves an existing connection from the pool.
func (p *connectionPool) getExisting(address string) net.Conn {
	p.mu.Lock()
	defer p.mu.Unlock()

	entries := p.connections[address]
	now := time.Now()

	// Look for a valid connection
	for i := len(entries) - 1; i >= 0; i-- {
		entry := entries[i]

		// Skip connections that are too old or idle
		if now.Sub(entry.createdAt) > p.maxLifetime ||
			now.Sub(entry.lastUsed) > p.idleTimeout {
			continue
		}

		// Remove this connection from the pool and return it
		p.connections[address] = append(entries[:i], entries[i+1:]...)

		return entry.conn
	}

	return nil
}

// put returns a connection to the pool or closes it if the pool is full.
func (p *connectionPool) put(address string, conn net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()

	// If pool is full for this address, close the connection
	if len(p.connections[address]) >= p.maxIdle {
		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection when pool is full: %v", err)
		}

		return
	}

	// Add the connection to the pool
	entry := &connEntry{
		conn:      conn,
		createdAt: time.Now(),
		lastUsed:  time.Now(),
	}

	p.connections[address] = append(p.connections[address], entry)
}

// close closes all connections in the pool and stops the cleanup goroutine.
func (p *connectionPool) close() {
	// Stop the cleanup goroutine
	if p.cleanupTicker != nil {
		p.cleanupTicker.Stop()
	}

	close(p.done)

	// Close all connections
	p.mu.Lock()
	defer p.mu.Unlock()

	for _, entries := range p.connections {
		for _, entry := range entries {
			if err := entry.conn.Close(); err != nil {
				log.Printf("Error closing connection during pool shutdown: %v", err)
			}
		}
	}

	// Clear the map
	p.connections = make(map[string][]*connEntry)
}

// TCPScanner implementation using the improved connection pool.
type TCPScanner struct {
	timeout     time.Duration
	concurrency int
	pool        *connectionPool
	dialer      *net.Dialer
}

func NewTCPScanner(timeout time.Duration, concurrency, maxIdle int, maxLifetime, idleTimeout time.Duration) *TCPScanner {
	dialer := &net.Dialer{
		Timeout:   timeout,
		KeepAlive: 30 * time.Second,
		Resolver: &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				// Use a very short timeout for DNS lookups.
				d := net.Dialer{Timeout: defaultDNSLookupTimeout}
				return d.DialContext(ctx, network, address)
			},
		},
	}

	return &TCPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		pool:        newConnectionPool(maxIdle, maxLifetime, idleTimeout),
		dialer:      dialer,
	}
}

// scanTarget performs a TCP scan of a single target with proper connection handling.
func (s *TCPScanner) scanTarget(ctx context.Context, target models.Target, results chan<- models.Result) {
	// Initialize the result with the target and timestamp information.
	result := models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Create a timeout context for this scan.
	scanCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	address := fmt.Sprintf("%s:%d", target.Host, target.Port)

	// Try to get a connection from the pool.
	conn, err := s.pool.get(scanCtx, s.dialer, address)
	if err != nil {
		result.Error = err
		result.Available = false
		s.sendResultOrCleanup(ctx, results, &result, conn)

		return
	}

	// Use a flag to decide whether the connection should be returned to the pool.
	var success bool
	defer func() {
		if success {
			s.pool.put(address, conn)
		} else {
			s.closeConn(conn, "scan failure")
		}
	}()

	// Do the actual scan.
	result.RespTime = time.Since(result.FirstSeen)
	result.Available = s.checkConnection(conn)

	success = true

	// Send the result; if context cancellation is detected, close the connection.
	s.sendResultOrCleanup(ctx, results, &result, conn)
}

// sendResultOrCleanup sends the result on the results channel. If the context is done,
// it ensures the connection is closed.
func (s *TCPScanner) sendResultOrCleanup(
	ctx context.Context, results chan<- models.Result, result *models.Result, conn net.Conn) {
	select {
	case results <- *result:
	case <-ctx.Done():
		s.closeConn(conn, "context cancellation during result send")
	}
}

// closeConn attempts to close the given connection and logs any error.
func (*TCPScanner) closeConn(conn net.Conn, reason string) {
	if conn != nil {
		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection (%s): %v", reason, err)
		}
	}
}

func (*TCPScanner) checkConnection(conn net.Conn) bool {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return true // Accept non-TCP connections as valid
	}

	// Set a longer read deadline (100ms) to avoid false negatives
	err := tcpConn.SetReadDeadline(time.Now().Add(defaultReadDeadline))
	if err != nil {
		log.Printf("Error setting read deadline: %v", err)

		return false
	}

	defer func() {
		if err = tcpConn.SetReadDeadline(time.Time{}); err != nil {
			log.Printf("Error resetting read deadline: %v", err)
		}
	}()

	// Try to read a single byte
	buf := make([]byte, 1)
	_, err = tcpConn.Read(buf)

	// Connection is considered valid if:
	// 1. Read succeeds (some services send banner)
	// 2. Read times out (most common for services that wait for client)
	// 3. Connection is closed by remote (service accepts and closes)
	if err != nil {
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return true // Timeout is expected and indicates port is open
		}

		if err.Error() == "EOF" {
			return true // EOF means connection was accepted then closed
		}
	}

	return err == nil // If no error, read succeeded
}

// Scan performs TCP scans for multiple targets concurrently.
func (s *TCPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Create buffered channel for results
	results := make(chan models.Result, len(targets))

	// Create semaphore for concurrency control
	semaphore := make(chan struct{}, s.concurrency)

	// Create wait group to track worker completion
	var wg sync.WaitGroup

	// Create separate context that can be canceled
	scanCtx, cancel := context.WithCancel(ctx)

	// Start worker goroutine
	go func() {
		defer close(results) // Ensure channel is closed when workers are done
		defer cancel()       // Ensure context is canceled

		for _, target := range targets {
			// Check if context was canceled
			if scanCtx.Err() != nil {
				return
			}

			// Add to wait group before starting goroutine
			wg.Add(1)

			// Start worker goroutine
			go func(target models.Target) {
				defer wg.Done()

				// Acquire semaphore
				select {
				case semaphore <- struct{}{}:
					defer func() { <-semaphore }()
				case <-scanCtx.Done():
					return
				}

				s.scanTarget(scanCtx, target, results)
			}(target)
		}

		// Wait for all workers to complete
		wg.Wait()
	}()

	return results, nil
}

// Stop gracefully shuts down the scanner.
func (s *TCPScanner) Stop(context.Context) error {
	if s.pool != nil {
		s.pool.close()
	}

	return nil
}
