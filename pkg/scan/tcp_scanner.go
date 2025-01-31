package scan

import (
	"context"
	"fmt"
	"hash/fnv"
	"log"
	"net"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	numShards = 32 // Experiment with different values
)

// connEntry represents a connection in the pool along with its last used timestamp.
type connEntry struct {
	conn      net.Conn
	lastUsed  time.Time
	createdAt time.Time
}

type shard struct {
	mu          sync.Mutex
	connections map[string][]*connEntry
}

// connectionPool manages a pool of reusable TCP connections.
type connectionPool struct {
	shards      [numShards]shard
	maxIdle     int
	maxLifetime time.Duration
	idleTimeout time.Duration
	dialer      *net.Dialer
}

// newConnectionPool creates a new connection pool.
func newConnectionPool(maxIdle int, maxLifetime, idleTimeout time.Duration, dialer *net.Dialer) *connectionPool {
	pool := &connectionPool{
		maxIdle:     maxIdle,
		maxLifetime: maxLifetime,
		idleTimeout: idleTimeout,
		dialer:      dialer,
	}

	for i := 0; i < numShards; i++ {
		pool.shards[i].connections = make(map[string][]*connEntry)
	}

	return pool
}

func (p *connectionPool) getShard(address string) *shard {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(address)) // Ignoring error as hash.Write never returns an error
	shardIndex := hash.Sum32() % numShards

	return &p.shards[shardIndex]
}

// get retrieves a connection from the pool for the given address.
func (p *connectionPool) get(ctx context.Context, address string) (net.Conn, error) {
	shard := p.getShard(address)
	shard.mu.Lock()

	// Clean up expired connections first
	p.cleanup(address)

	// Get an existing connection
	if entries, ok := shard.connections[address]; ok {
		for i := len(entries) - 1; i >= 0; i-- {
			entry := entries[i]
			if time.Since(entry.lastUsed) < p.idleTimeout && time.Since(entry.createdAt) < p.maxLifetime {
				// Remove the connection from the slice
				shard.connections[address] = append(entries[:i], entries[i+1:]...)
				shard.mu.Unlock()

				return entry.conn, nil
			}
		}
	}

	shard.mu.Unlock()

	// Create a new connection
	conn, err := p.dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}

	return conn, nil
}

// put returns a connection to the pool.
func (p *connectionPool) put(address string, conn net.Conn) {
	shard := p.getShard(address)
	shard.mu.Lock()
	defer shard.mu.Unlock()

	now := time.Now()

	entries, ok := shard.connections[address]
	if !ok {
		entries = []*connEntry{}
	}

	if len(entries) < p.maxIdle {
		shard.connections[address] = append(entries, &connEntry{
			conn:      conn,
			lastUsed:  now,
			createdAt: now,
		})
	} else {
		// Close the connection if the pool is full for this address
		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection: %v", err)
		}
	}
}

// cleanup removes expired connections from the pool.
func (p *connectionPool) cleanup(address string) {
	shard := p.getShard(address)

	if entries, ok := shard.connections[address]; ok {
		for i := len(entries) - 1; i >= 0; i-- {
			if time.Since(entries[i].lastUsed) >= p.idleTimeout || time.Since(entries[i].createdAt) >= p.maxLifetime {
				if err := entries[i].conn.Close(); err != nil {
					log.Printf("Error closing connection: %v", err)
				}

				shard.connections[address] = append(entries[:i], entries[i+1:]...) // Remove expired connection
			}
		}

		if len(shard.connections[address]) == 0 {
			delete(shard.connections, address) // Remove entry if no connections are left
		}
	}
}

// close closes all connections in the pool.
func (p *connectionPool) close() {
	for i := 0; i < numShards; i++ {
		shard := &p.shards[i]
		shard.mu.Lock()
		for _, entries := range shard.connections {
			for _, entry := range entries {
				if err := entry.conn.Close(); err != nil {
					log.Printf("Error closing connection: %v", err)
				}
			}
		}

		shard.connections = make(map[string][]*connEntry)

		shard.mu.Unlock()
	}
}

type TCPScanner struct {
	timeout     time.Duration
	concurrency int
	dialer      net.Dialer
	pool        *connectionPool
}

func NewTCPScanner(timeout time.Duration, concurrency, maxIdle int, maxLifetime, idleTimeout time.Duration) *TCPScanner {
	dialer := &net.Dialer{
		Timeout: timeout,
	}

	pool := newConnectionPool(maxIdle, maxLifetime, idleTimeout, dialer)

	return &TCPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		dialer:      *dialer,
		pool:        pool,
	}
}

func (s *TCPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	results := make(chan models.Result)
	targetChan := make(chan models.Target)

	// Start a fixed number of worker goroutines
	var wg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			for target := range targetChan {
				s.scanTarget(ctx, target, results)
			}
		}()
	}

	// Feed targets to the worker goroutines
	go func() {
		for _, target := range targets {
			select {
			case targetChan <- target:
			case <-ctx.Done():
				return
			}
		}

		close(targetChan) // Close the target channel to signal workers to stop
	}()

	// Close the results channel when all workers are done
	go func() {
		wg.Wait()
		close(results)
	}()

	return results, nil
}

func (s *TCPScanner) scanTarget(ctx context.Context, target models.Target, results chan<- models.Result) {
	result := models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	address := fmt.Sprintf("%s:%d", target.Host, target.Port)

	conn, err := s.pool.get(ctx, address)
	result.RespTime = time.Since(result.FirstSeen)

	if err != nil {
		result.Error = err
		result.Available = false
		sendResult(ctx, results, &result) // Send result and return early

		return
	}

	defer func() {
		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection: %v", err)
		}
	}()

	result.Available = s.checkConnection(conn, &result)
	s.pool.put(address, conn)

	sendResult(ctx, results, &result) // Send result
}

func sendResult(ctx context.Context, results chan<- models.Result, result *models.Result) {
	select {
	case results <- *result:
	case <-ctx.Done():
	}
}

func (*TCPScanner) checkConnection(conn net.Conn, result *models.Result) bool {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return true // or handle non-TCP connections appropriately
	}

	_ = tcpConn.SetReadDeadline(time.Now().Add(1 * time.Millisecond)) // Short read deadline
	defer func(tcpConn *net.TCPConn, t time.Time) {
		err := tcpConn.SetReadDeadline(t)
		if err != nil {
			log.Printf("Error resetting read deadline: %v", err)
		}
	}(tcpConn, time.Time{}) // Reset deadline on exit

	var one [1]byte

	_, err := tcpConn.Read(one[:])
	if err != nil {
		result.Error = fmt.Errorf("connection returned by pool is not valid: %w", err)

		return false
	}

	// Connection is still open but no data was read (successful read)
	return true
}

func (s *TCPScanner) Stop(context.Context) error {
	s.pool.close()
	return nil
}
