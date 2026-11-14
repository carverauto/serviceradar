/*
 * Copyright 2026 Carver Automation Corporation.
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

package snmp

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

var errTestCollectorStart = errors.New("collector start refused")

// feedCollector is a collector whose results the test sends by hand.
type feedCollector struct {
	results  chan DataPoint
	startErr error
}

func (c *feedCollector) Start(context.Context) error  { return c.startErr }
func (*feedCollector) Stop() error                    { return nil }
func (c *feedCollector) GetResults() <-chan DataPoint { return c.results }
func (*feedCollector) GetStatus() TargetStatus {
	return TargetStatus{Available: true, OIDStatus: make(map[string]OIDStatus)}
}

// feedCollectorFactory hands out a feedCollector per target and refuses to
// start the targets named in failStart.
type feedCollectorFactory struct {
	mu         sync.Mutex
	failStart  map[string]bool
	collectors map[string]*feedCollector
}

func (f *feedCollectorFactory) CreateCollector(target *Target, _ logger.Logger) (Collector, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	c := &feedCollector{results: make(chan DataPoint)}
	if f.failStart[target.Name] {
		c.startErr = errTestCollectorStart
	}

	if f.collectors == nil {
		f.collectors = make(map[string]*feedCollector)
	}
	f.collectors[target.Name] = c

	return c, nil
}

func (f *feedCollectorFactory) collector(name string) *feedCollector {
	f.mu.Lock()
	defer f.mu.Unlock()

	return f.collectors[name]
}

func scaleTestConfig(names ...string) *SNMPConfig {
	cfg := &SNMPConfig{Enabled: true}
	for _, name := range names {
		cfg.Targets = append(cfg.Targets, Target{
			Name:      name,
			Host:      "192.0.2.1",
			Port:      161,
			Community: "public",
			Version:   Version2c,
			Interval:  Duration(time.Hour),
			Timeout:   Duration(time.Second),
			OIDs:      []OIDConfig{{OID: ".1.3.6.1.2.1.1.3.0", Name: "sysUpTime", DataType: TypeGauge}},
		})
	}

	return cfg
}

func newFeedService(t *testing.T, factory *feedCollectorFactory, names ...string) *SNMPService {
	t.Helper()

	service, err := NewSNMPServiceForAgent(scaleTestConfig(names...), logger.NewTestLogger())
	require.NoError(t, err)
	service.collectorFactory = factory

	ctx, cancel := context.WithCancel(context.Background())
	require.NoError(t, service.Start(ctx))
	t.Cleanup(func() {
		cancel()
		_ = service.Stop()
	})

	return service
}

// A target that cannot start is reported unavailable with its reason; the
// targets around it still start and poll.
func TestServiceStartKeepsOtherTargetsWhenOneFailsToStart(t *testing.T) {
	factory := &feedCollectorFactory{failStart: map[string]bool{"target-b": true}}
	service := newFeedService(t, factory, "target-a", "target-b", "target-c")

	status, err := service.GetStatus(context.Background())
	require.NoError(t, err)
	require.Len(t, status, 3)

	assert.True(t, status["target-a"].Available)
	assert.True(t, status["target-c"].Available)
	assert.False(t, status["target-b"].Available)
	assert.Contains(t, status["target-b"].Error, errTestCollectorStart.Error())
	assert.Equal(t, "192.0.2.1", status["target-b"].HostIP)

	factory.collector("target-c").results <- DataPoint{OIDName: "sysUpTime", Value: 1.0, Timestamp: time.Now()}

	metrics, err := service.DrainMetrics(context.Background())
	require.NoError(t, err)
	assert.Len(t, metrics["target-c|sysUpTime"], 1)
}

// blockingAggregator wraps a real aggregator; Drain parks until released.
type blockingAggregator struct {
	Aggregator
	draining chan struct{}
	release  chan struct{}
}

func (a *blockingAggregator) Drain() map[string][]DataPoint {
	close(a.draining)
	<-a.release

	return a.Aggregator.Drain()
}

type stallingAggregatorFactory struct {
	stallFirst *blockingAggregator
	created    int
}

func (f *stallingAggregatorFactory) CreateAggregator(interval time.Duration, maxPoints int) (Aggregator, error) {
	f.created++
	if f.created == 1 {
		f.stallFirst.Aggregator = NewAggregator(interval, maxPoints)
		return f.stallFirst, nil
	}

	return NewAggregator(interval, maxPoints), nil
}

// A drain in progress must not stall other targets' results or status reads:
// polling waits on the results channel, so a drain that blocked results would
// stall every poll for as long as it runs.
func TestServiceDrainDoesNotStallOtherTargets(t *testing.T) {
	slow := &blockingAggregator{draining: make(chan struct{}), release: make(chan struct{})}
	factory := &feedCollectorFactory{}

	service, err := NewSNMPServiceForAgent(scaleTestConfig("target-slow", "target-busy"), logger.NewTestLogger())
	require.NoError(t, err)
	service.collectorFactory = factory
	service.aggregatorFactory = &stallingAggregatorFactory{stallFirst: slow}
	require.NoError(t, service.Start(context.Background()))
	t.Cleanup(func() { _ = service.Stop() })

	drained := make(chan struct{})
	go func() {
		defer close(drained)
		_, _ = service.DrainMetrics(context.Background())
	}()
	<-slow.draining

	delivered := make(chan struct{})
	go func() {
		defer close(delivered)
		for i := 0; i < 3; i++ {
			factory.collector("target-busy").results <- DataPoint{
				OIDName:   "sysName",
				Value:     fmt.Sprintf("busy-%d", i),
				Timestamp: time.Now(),
			}
		}
	}()

	select {
	case <-delivered:
	case <-time.After(5 * time.Second):
		close(slow.release)
		t.Fatal("results of another target stalled behind a drain")
	}

	statusRead := make(chan map[string]TargetStatus)
	go func() {
		status, _ := service.GetStatus(context.Background())
		statusRead <- status
	}()

	select {
	case status := <-statusRead:
		// The third point was received; the status reflects at least the second.
		assert.Contains(t, []string{"busy-1", "busy-2"}, status["target-busy"].HostName)
	case <-time.After(5 * time.Second):
		close(slow.release)
		t.Fatal("status read stalled behind a drain")
	}

	close(slow.release)
	<-drained

	assert.Eventually(t, func() bool {
		status, err := service.GetStatus(context.Background())
		return err == nil && status["target-busy"].HostName == "busy-2"
	}, 5*time.Second, 10*time.Millisecond)
}

// A series holds what has been collected since the last drain, not its
// MaxPoints retention bound. Preallocating the bound cost about 200 KB per series
// (MaxPoints 1,000 x a ~200-byte DataPoint), which is about 2.6 MB for a
// 13-series target, whether or not a point was ever buffered.
func TestServiceMemoryPerTargetFollowsBufferedPoints(t *testing.T) {
	const (
		targets           = 20
		seriesPerTarget   = 13
		maxBytesPerTarget = 128 << 10
	)

	names := make([]string, targets)
	for i := range names {
		names[i] = fmt.Sprintf("target-%02d", i)
	}

	runtime.GC()

	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	factory := &feedCollectorFactory{}
	service := newFeedService(t, factory, names...)

	for _, name := range names {
		results := factory.collector(name).results
		for s := 0; s < seriesPerTarget; s++ {
			results <- DataPoint{OIDName: fmt.Sprintf("series-%02d", s), Value: 1.0, Timestamp: time.Now()}
		}
		// The results channel is unbuffered, so once this send returns every
		// point above has been added.
		results <- DataPoint{OIDName: "series-00", Value: 2.0, Timestamp: time.Now()}
	}

	runtime.GC()

	var after runtime.MemStats
	runtime.ReadMemStats(&after)

	perTarget := (int64(after.HeapAlloc) - int64(before.HeapAlloc)) / targets
	assert.Less(t, perTarget, int64(maxBytesPerTarget), "retained heap per target")

	metrics, err := service.DrainMetrics(context.Background())
	require.NoError(t, err)
	assert.Len(t, metrics, targets*seriesPerTarget)
	runtime.KeepAlive(service)
}

// Starting targets opens no sockets: a target holds a socket only while it is
// being polled. A socket per target capped one agent at its ephemeral port range
// (about 28,000 on stock Linux), and the first refused socket failed Start for
// every target.
func TestServiceStartOpensNoSocketPerTarget(t *testing.T) {
	if _, err := os.ReadDir("/proc/self/fd"); err != nil {
		t.Skip("counting open descriptors needs /proc/self/fd")
	}

	const targets = 200

	names := make([]string, targets)
	for i := range names {
		names[i] = fmt.Sprintf("target-%03d", i)
	}

	cfg := scaleTestConfig(names...)
	for i := range cfg.Targets {
		cfg.Targets[i].Host = "127.0.0.1"
	}

	service, err := NewSNMPServiceForAgent(cfg, logger.NewTestLogger())
	require.NoError(t, err)

	fdsBefore := countOpenFDs(t)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	require.NoError(t, service.Start(ctx))
	t.Cleanup(func() { _ = service.Stop() })

	assert.Less(t, countOpenFDs(t)-fdsBefore, targets/10, "descriptors opened by starting %d targets", targets)

	status, err := service.GetStatus(ctx)
	require.NoError(t, err)
	assert.Len(t, status, targets)
}

func countOpenFDs(t *testing.T) int {
	t.Helper()

	entries, err := os.ReadDir("/proc/self/fd")
	require.NoError(t, err)

	return len(entries)
}

// Polls past the session bound wait for a session to free up rather than open
// another socket.
func TestCollectorPollsBeyondSessionBoundWait(t *testing.T) {
	ctrl := gomock.NewController(t)
	sessions := newSessionSlots(1)
	oids := []OIDConfig{{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName", DataType: TypeString}}

	firstInGet := make(chan struct{})
	releaseFirst := make(chan struct{})

	first := NewMockSNMPClient(ctrl)
	first.EXPECT().Get(gomock.Any()).DoAndReturn(func([]string) (map[string]interface{}, error) {
		close(firstInGet)
		<-releaseFirst

		return map[string]interface{}{".1.3.6.1.2.1.1.5.0": "host-a"}, nil
	})
	first.EXPECT().Close().Return(nil)

	secondInGet := make(chan struct{})
	second := NewMockSNMPClient(ctrl)
	second.EXPECT().Get(gomock.Any()).DoAndReturn(func([]string) (map[string]interface{}, error) {
		close(secondInGet)

		return map[string]interface{}{".1.3.6.1.2.1.1.5.0": "host-b"}, nil
	})
	second.EXPECT().Close().Return(nil)

	firstCollector := newTestCollector(first, oids)
	firstCollector.sessions = sessions
	secondCollector := newTestCollector(second, oids)
	secondCollector.sessions = sessions

	polls := make(chan error, 2)
	go func() { polls <- firstCollector.pollTarget(context.Background()) }()
	<-firstInGet
	go func() { polls <- secondCollector.pollTarget(context.Background()) }()

	select {
	case <-secondInGet:
		t.Fatal("a second session opened while the only one was in use")
	case <-time.After(100 * time.Millisecond):
	}

	close(releaseFirst)

	select {
	case <-secondInGet:
	case <-time.After(5 * time.Second):
		t.Fatal("the waiting poll never got the freed session")
	}

	require.NoError(t, <-polls)
	require.NoError(t, <-polls)
}

// startGetResponder answers every SNMP v2c GET on a loopback UDP port with an
// OctetString for each requested OID, until the test ends.
func startGetResponder(t *testing.T) uint16 {
	t.Helper()

	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })

	go func() {
		decoder := &gosnmp.GoSNMP{Version: gosnmp.Version2c}
		buf := make([]byte, 65535)

		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}

			request, err := decoder.SnmpDecodePacket(append([]byte(nil), buf[:n]...))
			if err != nil {
				continue
			}

			variables := make([]gosnmp.SnmpPDU, 0, len(request.Variables))
			for _, v := range request.Variables {
				variables = append(variables, gosnmp.SnmpPDU{Name: v.Name, Type: gosnmp.OctetString, Value: []byte("host01")})
			}

			response := &gosnmp.SnmpPacket{
				Version:   request.Version,
				Community: request.Community,
				PDUType:   gosnmp.GetResponse,
				RequestID: request.RequestID,
				Variables: variables,
			}

			out, err := response.MarshalMsg()
			if err == nil {
				_, _ = conn.WriteToUDP(out, addr)
			}
		}
	}()

	return uint16(conn.LocalAddr().(*net.UDPAddr).Port)
}

// A closed session keeps nothing of its socket: gosnmp allocates a 64 KiB
// receive buffer for every connection, and a client that kept its connected
// gosnmp value between polls pinned that buffer for every target.
func TestClientRetainsNoReceiveBufferBetweenPolls(t *testing.T) {
	const (
		clients           = 40
		maxBytesPerClient = 16 << 10
	)

	port := startGetResponder(t)
	target := Target{
		Name:      "host01",
		Host:      "127.0.0.1",
		Port:      port,
		Community: "public",
		Version:   Version2c,
		Interval:  Duration(time.Hour),
		Timeout:   Duration(2 * time.Second),
		Retries:   1,
		OIDs:      []OIDConfig{{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName", DataType: TypeString}},
	}

	runtime.GC()

	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	polled := make([]SNMPClient, clients)
	for i := range polled {
		clientTarget := target
		client, err := newSNMPClient(&clientTarget)
		require.NoError(t, err)

		values, err := client.Get([]string{".1.3.6.1.2.1.1.5.0"})
		require.NoError(t, err)
		require.Equal(t, "host01", values[".1.3.6.1.2.1.1.5.0"])
		require.NoError(t, client.Close())

		polled[i] = client
	}

	runtime.GC()

	var after runtime.MemStats
	runtime.ReadMemStats(&after)

	perClient := (int64(after.HeapAlloc) - int64(before.HeapAlloc)) / clients
	assert.Less(t, perClient, int64(maxBytesPerClient), "retained heap per polled client")
	runtime.KeepAlive(polled)
}
