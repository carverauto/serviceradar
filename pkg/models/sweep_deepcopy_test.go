package models

import (
	"testing"
	"time"
)

func TestDeepCopyHostResult_NoAliasing(t *testing.T) {
	icmp := &ICMPStatus{Available: true, RoundTrip: 10 * time.Millisecond, PacketLoss: 0}
	pr80 := &PortResult{Port: 80, Available: true, RespTime: 5 * time.Millisecond, Service: "http"}
	pr443 := &PortResult{Port: 443, Available: false, RespTime: 0, Service: "https"}

	src := &HostResult{
		Host:         "192.168.1.1",
		Available:    true,
		FirstSeen:    time.Unix(100, 0),
		LastSeen:     time.Unix(200, 0),
		PortResults:  []*PortResult{pr80, pr443},
		PortMap:      map[int]*PortResult{80: pr80, 443: pr443},
		ICMPStatus:   icmp,
		ResponseTime: 11 * time.Millisecond,
	}

	dst := DeepCopyHostResult(src)

	if dst.Host != src.Host || dst.Available != src.Available || !dst.FirstSeen.Equal(src.FirstSeen) || !dst.LastSeen.Equal(src.LastSeen) || dst.ResponseTime != src.ResponseTime {
		t.Fatalf("expected scalar fields to match")
	}

	if dst.ICMPStatus == nil || src.ICMPStatus == nil {
		t.Fatalf("expected ICMPStatus to be non-nil")
	}
	if dst.ICMPStatus == src.ICMPStatus {
		t.Fatalf("expected ICMPStatus to be deep-copied")
	}
	if *dst.ICMPStatus != *src.ICMPStatus {
		t.Fatalf("expected ICMPStatus values to match")
	}

	if dst.PortResults == nil || len(dst.PortResults) != len(src.PortResults) {
		t.Fatalf("expected PortResults to be copied")
	}
	if dst.PortMap == nil || len(dst.PortMap) != len(src.PortMap) {
		t.Fatalf("expected PortMap to be copied")
	}
	if &dst.PortResults[0] == &src.PortResults[0] {
		t.Fatalf("unexpected slice aliasing")
	}

	for i := range src.PortResults {
		if src.PortResults[i] == nil || dst.PortResults[i] == nil {
			t.Fatalf("unexpected nil PortResult at index %d", i)
		}
		if src.PortResults[i] == dst.PortResults[i] {
			t.Fatalf("expected PortResults[%d] to be deep-copied", i)
		}
		if *src.PortResults[i] != *dst.PortResults[i] {
			t.Fatalf("expected PortResults[%d] values to match", i)
		}
		if got := dst.PortMap[dst.PortResults[i].Port]; got != dst.PortResults[i] {
			t.Fatalf("expected PortMap to reference the same copied PortResult for port %d", dst.PortResults[i].Port)
		}
	}

	dst.PortResults[0].Available = false
	dst.PortMap[80].Service = "changed"
	dst.ICMPStatus.PacketLoss = 50

	if src.PortResults[0].Available == dst.PortResults[0].Available {
		t.Fatalf("expected PortResults mutation not to affect source")
	}
	if src.PortMap[80].Service == dst.PortMap[80].Service {
		t.Fatalf("expected PortMap mutation not to affect source")
	}
	if src.ICMPStatus.PacketLoss == dst.ICMPStatus.PacketLoss {
		t.Fatalf("expected ICMPStatus mutation not to affect source")
	}
}
