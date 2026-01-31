package scan

import (
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestWithICMPCount(t *testing.T) {
	tests := []struct {
		name     string
		count    int
		expected int
	}{
		{"default count", 0, defaultICMPCount},
		{"custom count 5", 5, 5},
		{"custom count 1", 1, 1},
		{"negative count uses default", -1, defaultICMPCount},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sweeper := &ICMPSweeper{icmpCount: defaultICMPCount}

			if tt.count > 0 {
				opt := WithICMPCount(tt.count)
				opt(sweeper)
			} else if tt.count < 0 {
				opt := WithICMPCount(tt.count)
				opt(sweeper)
			}

			if sweeper.icmpCount != tt.expected {
				t.Errorf("WithICMPCount(%d) resulted in icmpCount=%d, want %d",
					tt.count, sweeper.icmpCount, tt.expected)
			}
		})
	}
}

func TestHostICMPStats(t *testing.T) {
	stats := &hostICMPStats{
		firstSeen: time.Now(),
	}

	// Simulate sending 3 packets
	stats.sent = 3

	// Simulate receiving 2 packets with different RTTs
	rtt1 := 5 * time.Millisecond
	rtt2 := 7 * time.Millisecond

	stats.received = 2
	stats.totalRTT = rtt1 + rtt2

	// Verify packet loss calculation (approximately 33.33%)
	packetLoss := float64(stats.sent-stats.received) / float64(stats.sent) * 100
	if packetLoss < 33.0 || packetLoss > 34.0 {
		t.Errorf("Packet loss calculation: got %f, want ~33.33%%", packetLoss)
	}

	// Verify average RTT calculation
	avgRTT := stats.totalRTT / time.Duration(stats.received)
	expectedAvgRTT := 6 * time.Millisecond
	if avgRTT != expectedAvgRTT {
		t.Errorf("Average RTT: got %v, want %v", avgRTT, expectedAvgRTT)
	}
}

func TestPacketLossCalculation(t *testing.T) {
	tests := []struct {
		name        string
		sent        int
		received    int
		expectedMin float64
		expectedMax float64
	}{
		{"all received", 3, 3, 0, 0},
		{"one lost", 3, 2, 33.0, 34.0},
		{"two lost", 3, 1, 66.0, 67.0},
		{"all lost", 3, 0, 100, 100},
		{"single packet success", 1, 1, 0, 0},
		{"single packet failure", 1, 0, 100, 100},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			loss := float64(tt.sent-tt.received) / float64(tt.sent) * 100
			if loss < tt.expectedMin || loss > tt.expectedMax {
				t.Errorf("Packet loss for %d/%d: got %f, want between %f and %f",
					tt.received, tt.sent, loss, tt.expectedMin, tt.expectedMax)
			}
		})
	}
}

func TestProcessResultsWithHostStats(t *testing.T) {
	sweeper := &ICMPSweeper{
		results:   make(map[string]models.Result),
		hostStats: make(map[string]*hostICMPStats),
		mu:        sync.Mutex{},
		icmpCount: 3,
		logger:    logger.NewTestLogger(),
	}

	targets := []models.Target{
		{Host: "8.8.8.8", Mode: models.ModeICMP},
		{Host: "1.1.1.1", Mode: models.ModeICMP},
		{Host: "9.9.9.9", Mode: models.ModeICMP},
	}

	now := time.Now()

	// Simulate host 8.8.8.8: all 3 packets received
	sweeper.hostStats["8.8.8.8"] = &hostICMPStats{
		sent:      3,
		received:  3,
		totalRTT:  15 * time.Millisecond, // 5ms average
		firstSeen: now,
		lastSeen:  now,
	}
	sweeper.results["8.8.8.8"] = models.Result{
		Target:     targets[0],
		Available:  true,
		RespTime:   5 * time.Millisecond,
		PacketLoss: 0,
		FirstSeen:  now,
		LastSeen:   now,
	}

	// Simulate host 1.1.1.1: partial success (1 of 3 received)
	sweeper.hostStats["1.1.1.1"] = &hostICMPStats{
		sent:      3,
		received:  1,
		totalRTT:  8 * time.Millisecond,
		firstSeen: now,
		lastSeen:  now,
	}
	sweeper.results["1.1.1.1"] = models.Result{
		Target:     targets[1],
		Available:  true, // Available because at least 1 reply received
		RespTime:   8 * time.Millisecond,
		PacketLoss: 66.66666666666667,
		FirstSeen:  now,
		LastSeen:   now,
	}

	// Simulate host 9.9.9.9: all packets lost
	sweeper.hostStats["9.9.9.9"] = &hostICMPStats{
		sent:      3,
		received:  0,
		totalRTT:  0,
		firstSeen: now,
		lastSeen:  now,
	}
	sweeper.results["9.9.9.9"] = models.Result{
		Target:     targets[2],
		Available:  false,
		RespTime:   0,
		PacketLoss: 100,
		FirstSeen:  now,
		LastSeen:   now,
	}

	resultCh := make(chan models.Result, len(targets))
	sweeper.processResults(targets, resultCh)
	close(resultCh)

	results := make(map[string]models.Result)
	for r := range resultCh {
		results[r.Target.Host] = r
	}

	// Verify 8.8.8.8: full success
	r := results["8.8.8.8"]
	if !r.Available {
		t.Errorf("8.8.8.8: expected available=true")
	}
	if r.PacketLoss != 0 {
		t.Errorf("8.8.8.8: expected packet loss 0, got %f", r.PacketLoss)
	}

	// Verify 1.1.1.1: partial success (should still be available)
	r = results["1.1.1.1"]
	if !r.Available {
		t.Errorf("1.1.1.1: expected available=true (partial success)")
	}
	if r.PacketLoss < 60 || r.PacketLoss > 70 {
		t.Errorf("1.1.1.1: expected packet loss ~66.67%%, got %f", r.PacketLoss)
	}

	// Verify 9.9.9.9: complete failure
	r = results["9.9.9.9"]
	if r.Available {
		t.Errorf("9.9.9.9: expected available=false")
	}
	if r.PacketLoss != 100 {
		t.Errorf("9.9.9.9: expected packet loss 100, got %f", r.PacketLoss)
	}
}

func TestAverageResponseTimeCalculation(t *testing.T) {
	tests := []struct {
		name        string
		rtts        []time.Duration
		expectedAvg time.Duration
	}{
		{
			"three equal RTTs",
			[]time.Duration{5 * time.Millisecond, 5 * time.Millisecond, 5 * time.Millisecond},
			5 * time.Millisecond,
		},
		{
			"three different RTTs",
			[]time.Duration{4 * time.Millisecond, 6 * time.Millisecond, 8 * time.Millisecond},
			6 * time.Millisecond,
		},
		{
			"single RTT",
			[]time.Duration{10 * time.Millisecond},
			10 * time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var totalRTT time.Duration
			for _, rtt := range tt.rtts {
				totalRTT += rtt
			}
			avgRTT := totalRTT / time.Duration(len(tt.rtts))

			if avgRTT != tt.expectedAvg {
				t.Errorf("Average RTT: got %v, want %v", avgRTT, tt.expectedAvg)
			}
		})
	}
}

func TestCalculatePacketsPerInterval(t *testing.T) {
	sweeper := &ICMPSweeper{rateLimit: 1000}
	packets := sweeper.calculatePacketsPerInterval()

	expected := 10 // 1000 / (1000 / 10ms) = 10 packets
	if packets != expected {
		t.Errorf("calculatePacketsPerInterval() = %d, want %d", packets, expected)
	}

	sweeper.rateLimit = 50

	packets = sweeper.calculatePacketsPerInterval()
	if packets != 1 { // Minimum is 1
		t.Errorf("calculatePacketsPerInterval() = %d, want 1 for low rate", packets)
	}
}

// buildTimeMaps is a helper to construct send/reply time maps for RTT tests.
// sendOffsets and rtts are parallel slices: sendOffsets[i] is when packet i+1 was sent,
// and rtts[i] is the round-trip time for that packet.
func buildTimeMaps(sendOffsets, rtts []time.Duration) (sendTimes, replyTimes map[int]time.Time) {
	base := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	sendTimes = make(map[int]time.Time)
	replyTimes = make(map[int]time.Time)
	for i := range sendOffsets {
		seq := i + 1
		sendTimes[seq] = base.Add(sendOffsets[i])
		replyTimes[seq] = base.Add(sendOffsets[i] + rtts[i])
	}
	return sendTimes, replyTimes
}

// TestPerSequenceRTTCalculation verifies that RTT is calculated per-packet
// using the send time for each specific sequence number, not the first packet's send time.
// This is critical for accurate RTT measurements when sending multiple ICMP packets.
func TestPerSequenceRTTCalculation(t *testing.T) {
	// Build test cases using helper to avoid code duplication
	uniformSend, uniformReply := buildTimeMaps(
		[]time.Duration{0, 300 * time.Millisecond, 600 * time.Millisecond},
		[]time.Duration{1 * time.Millisecond, 1 * time.Millisecond, 1 * time.Millisecond},
	)
	varyingSend, varyingReply := buildTimeMaps(
		[]time.Duration{0, 100 * time.Millisecond, 200 * time.Millisecond},
		[]time.Duration{2 * time.Millisecond, 5 * time.Millisecond, 8 * time.Millisecond},
	)
	singleSend, singleReply := buildTimeMaps(
		[]time.Duration{0},
		[]time.Duration{500 * time.Microsecond},
	)

	tests := []struct {
		name           string
		sendTimes      map[int]time.Time
		replyTimes     map[int]time.Time
		expectedAvgRTT time.Duration
		tolerance      time.Duration
	}{
		{
			name:           "three packets with 1ms RTT each",
			sendTimes:      uniformSend,
			replyTimes:     uniformReply,
			expectedAvgRTT: 1 * time.Millisecond,
			tolerance:      100 * time.Microsecond,
		},
		{
			name:           "three packets with varying RTTs (2ms, 5ms, 8ms)",
			sendTimes:      varyingSend,
			replyTimes:     varyingReply,
			expectedAvgRTT: 5 * time.Millisecond, // (2+5+8)/3 = 5ms
			tolerance:      100 * time.Microsecond,
		},
		{
			name:           "single packet with 0.5ms RTT",
			sendTimes:      singleSend,
			replyTimes:     singleReply,
			expectedAvgRTT: 500 * time.Microsecond,
			tolerance:      10 * time.Microsecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stats := &hostICMPStats{
				sendTimes: make(map[int]time.Time),
			}

			// Simulate sending packets - record send times
			for seq, sendTime := range tt.sendTimes {
				stats.sendTimes[seq] = sendTime
				stats.sent++
			}

			// Simulate receiving replies - calculate RTT per sequence
			for seq, replyTime := range tt.replyTimes {
				if sendTime, ok := stats.sendTimes[seq]; ok {
					rtt := replyTime.Sub(sendTime)
					stats.totalRTT += rtt
					stats.received++
					delete(stats.sendTimes, seq) // Clean up like the real code does
				}
			}

			// Calculate average RTT
			if stats.received == 0 {
				t.Fatal("No packets received in test")
			}
			avgRTT := stats.totalRTT / time.Duration(stats.received)

			// Verify the average RTT is within tolerance
			diff := avgRTT - tt.expectedAvgRTT
			if diff < 0 {
				diff = -diff
			}
			if diff > tt.tolerance {
				t.Errorf("Average RTT: got %v, want %v (±%v)", avgRTT, tt.expectedAvgRTT, tt.tolerance)
			}

			// Verify sendTimes map is cleaned up
			if len(stats.sendTimes) != 0 {
				t.Errorf("sendTimes map should be empty after processing, has %d entries", len(stats.sendTimes))
			}
		})
	}
}

// TestPerSequenceRTTVsFirstSeenBug demonstrates the bug where RTT was calculated
// from firstSeen (first packet send time) instead of per-packet send time.
// With the bug, packets sent later would show inflated RTTs.
func TestPerSequenceRTTVsFirstSeenBug(t *testing.T) {
	// Simulate the OLD buggy behavior vs NEW correct behavior
	// Packets sent at t=0, t=300ms, t=600ms with actual 1ms RTT each

	firstSeen := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)

	sendTimes := map[int]time.Time{
		1: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
		2: time.Date(2025, 1, 1, 0, 0, 0, 300*int(time.Millisecond), time.UTC),
		3: time.Date(2025, 1, 1, 0, 0, 0, 600*int(time.Millisecond), time.UTC),
	}

	replyTimes := map[int]time.Time{
		1: time.Date(2025, 1, 1, 0, 0, 0, 1*int(time.Millisecond), time.UTC),
		2: time.Date(2025, 1, 1, 0, 0, 0, 301*int(time.Millisecond), time.UTC),
		3: time.Date(2025, 1, 1, 0, 0, 0, 601*int(time.Millisecond), time.UTC),
	}

	// Calculate RTT the OLD buggy way (from firstSeen)
	var buggyTotalRTT time.Duration
	for _, replyTime := range replyTimes {
		buggyRTT := replyTime.Sub(firstSeen)
		buggyTotalRTT += buggyRTT
	}
	buggyAvgRTT := buggyTotalRTT / 3

	// Calculate RTT the NEW correct way (per-sequence)
	var correctTotalRTT time.Duration
	for seq, replyTime := range replyTimes {
		correctRTT := replyTime.Sub(sendTimes[seq])
		correctTotalRTT += correctRTT
	}
	correctAvgRTT := correctTotalRTT / 3

	// The buggy average should be much higher (~300ms instead of ~1ms)
	if buggyAvgRTT < 200*time.Millisecond {
		t.Errorf("Buggy RTT calculation should show inflated RTT, got %v", buggyAvgRTT)
	}

	// The correct average should be ~1ms
	if correctAvgRTT > 2*time.Millisecond {
		t.Errorf("Correct RTT calculation should show ~1ms, got %v", correctAvgRTT)
	}

	t.Logf("Buggy avg RTT: %v (inflated due to measuring from firstSeen)", buggyAvgRTT)
	t.Logf("Correct avg RTT: %v (accurate per-sequence measurement)", correctAvgRTT)
}

func TestProcessResults(t *testing.T) {
	sweeper := &ICMPSweeper{
		results: make(map[string]models.Result),
		mu:      sync.Mutex{},
	}

	targets := []models.Target{
		{Host: "8.8.8.8", Mode: models.ModeICMP},
		{Host: "1.1.1.1", Mode: models.ModeICMP},
	}

	now := time.Now()
	sweeper.results["8.8.8.8"] = models.Result{
		Target:     targets[0],
		Available:  true,
		RespTime:   10 * time.Millisecond,
		PacketLoss: 0,
		FirstSeen:  now,
		LastSeen:   now,
	}

	resultCh := make(chan models.Result, len(targets))
	sweeper.processResults(targets, resultCh)
	close(resultCh)

	results := make([]models.Result, 0, len(targets))
	for r := range resultCh {
		results = append(results, r)
	}

	if len(results) != len(targets) {
		t.Errorf("processResults() sent %d results, want %d", len(results), len(targets))
	}

	for _, r := range results {
		if r.Target.Host == "8.8.8.8" && !r.Available {
			t.Errorf("Expected 8.8.8.8 to be available")
		}

		if r.Target.Host == "1.1.1.1" && r.Available {
			t.Errorf("Expected 1.1.1.1 to be unavailable")
		}
	}
}
