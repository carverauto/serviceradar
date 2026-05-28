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

package netprobe

import (
	"context"
	"net"
	"reflect"
	"testing"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func TestSidecarDefaultsAndArgs(t *testing.T) {
	sc := NewSidecar(SidecarConfig{HealthPort: 18080, ExtraArgs: []string{"--extra"}})
	if sc.Name() != DefaultSidecarName {
		t.Fatalf("Name() = %q, want %q", sc.Name(), DefaultSidecarName)
	}
	if sc.BinaryPath() != DefaultBinaryPath {
		t.Fatalf("BinaryPath() = %q, want %q", sc.BinaryPath(), DefaultBinaryPath)
	}

	got := sc.Args("/tmp/netprobe.sock", "/tmp/netprobe.json")
	want := []string{
		"--socket", "/tmp/netprobe.sock",
		"--config", "/tmp/netprobe.json",
		"--log-format", "json",
		"--health-port", "18080",
		"--extra",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Args() = %#v, want %#v", got, want)
	}
}

func TestSidecarCapturesEngineVersionOnHealthy(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	go handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
		ping := frame.GetPing()
		return &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_PingAck{
				PingAck: &netprobepb.PingAck{
					SentAtUnixNano:           ping.GetSentAtUnixNano(),
					AckedAtUnixNano:          ping.GetSentAtUnixNano() + 1,
					FingerprintEngineVersion: "engine-v1",
				},
			},
		}
	})

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()
	if err := client.Ping(context.Background()); err != nil {
		t.Fatalf("Ping() error = %v", err)
	}

	sc := NewSidecar(SidecarConfig{})
	sc.OnHealthy(client)
	if !sc.Healthy() {
		t.Fatal("Healthy() = false, want true")
	}
	if got := sc.FingerprintEngineVersion(); got != "engine-v1" {
		t.Fatalf("FingerprintEngineVersion() = %q, want engine-v1", got)
	}
}
