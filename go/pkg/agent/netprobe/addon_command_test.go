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
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
)

type fakeAddonCommandServer struct {
	addonpb.UnimplementedAddonServiceServer

	lastRequest *addonpb.RunCommandRequest
	respond     func(*addonpb.RunCommandRequest) *addonpb.RunCommandResponse
}

func (f *fakeAddonCommandServer) RunCommand(
	_ context.Context,
	req *addonpb.RunCommandRequest,
) (*addonpb.RunCommandResponse, error) {
	f.lastRequest = req

	return f.respond(req), nil
}

// serveFakeAddon starts an AddonService on a unix socket and returns its path.
// os.MkdirTemp rather than t.TempDir: a unix socket path is capped near 104
// bytes and macOS t.TempDir paths embed the test name, which blows the cap.
func serveFakeAddon(t *testing.T, server *fakeAddonCommandServer) string {
	t.Helper()

	dir, err := os.MkdirTemp("", "np")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	path := filepath.Join(dir, "addon.sock")
	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(context.Background(), "unix", path)
	require.NoError(t, err)

	grpcServer := grpc.NewServer()
	addonpb.RegisterAddonServiceServer(grpcServer, server)

	go func() { _ = grpcServer.Serve(listener) }()
	t.Cleanup(grpcServer.Stop)

	return path
}

func okResponse(payload string) func(*addonpb.RunCommandRequest) *addonpb.RunCommandResponse {
	return func(*addonpb.RunCommandRequest) *addonpb.RunCommandResponse {
		return &addonpb.RunCommandResponse{Success: true, PayloadJson: []byte(payload)}
	}
}

func TestAddonCommandClientMatchesBannersOverRunCommand(t *testing.T) {
	server := &fakeAddonCommandServer{
		respond: okResponse(`{"observations":1,"matches":[{"observation_id":42,` +
			`"corpus_label":"recog:http.server","os_family":"Linux","product":"HTTPD",` +
			`"version":"2.4.58","confidence":0.86,"raw_pattern_id":"apache"}]}`),
	}
	client := NewAddonCommandClient(serveFakeAddon(t, server))
	t.Cleanup(func() { _ = client.Close() })

	matches, err := client.MatchBanners(context.Background(), &netprobepb.BannerBatch{
		Observations: []*netprobepb.BannerObservation{{
			ObservationId: 42,
			Host:          "192.0.2.10",
			Port:          80,
			Protocol:      "http",
			BannerBytes:   []byte("Apache/2.4.58 (Ubuntu)"),
			ObservedAt:    1_700_000_000_000_000_000,
			Source:        "sweep_active",
		}},
	})
	require.NoError(t, err)

	require.Len(t, matches.GetMatches(), 1)
	require.Equal(t, uint64(42), matches.GetMatches()[0].GetObservationId())
	require.Equal(t, "HTTPD", matches.GetMatches()[0].GetProduct())
	require.Equal(t, "2.4.58", matches.GetMatches()[0].GetVersion())
	require.InDelta(t, 0.86, matches.GetMatches()[0].GetConfidence(), 1e-9)

	require.Equal(t, matchBannersAction, server.lastRequest.GetActionId())
	require.Equal(t, matchBannersSchema, server.lastRequest.GetSchema())
	require.Equal(t, addonRunCommandType, server.lastRequest.GetCommandType())
}

func TestMatchBannersRequestCarriesOnlyTheMatcherInputs(t *testing.T) {
	server := &fakeAddonCommandServer{respond: okResponse(`{"observations":1,"matches":[]}`)}
	client := NewAddonCommandClient(serveFakeAddon(t, server))
	t.Cleanup(func() { _ = client.Close() })

	_, err := client.MatchBanners(context.Background(), &netprobepb.BannerBatch{
		Observations: []*netprobepb.BannerObservation{{
			ObservationId: 7,
			Host:          "192.0.2.10",
			Port:          22,
			Protocol:      "ssh",
			BannerBytes:   []byte("SSH-2.0-OpenSSH_8.9p1"),
			ObservedAt:    1_700_000_000_000_000_000,
			Source:        "sweep_active",
		}},
	})
	require.NoError(t, err)

	var sent map[string]any
	require.NoError(t, json.Unmarshal(server.lastRequest.GetPayloadJson(), &sent))
	observation, ok := sent["observations"].([]any)[0].(map[string]any)
	require.True(t, ok)

	// Asserted, not assumed. host/port/source/observed_at stay on the agent: it
	// re-attaches them when building the fingerprint event, and a second copy over
	// the wire would be a second source of truth for the same observation.
	// observed_at is the sharp one -- nanoseconds since epoch exceed 2^53, so any
	// consumer parsing JSON numbers as doubles would silently truncate it.
	require.ElementsMatch(t,
		[]string{"observation_id", "protocol", "banner_b64"},
		keysOf(observation),
	)
}

func TestMatchBannersEncodesBinaryBannersAsBase64(t *testing.T) {
	server := &fakeAddonCommandServer{respond: okResponse(`{"observations":1,"matches":[]}`)}
	client := NewAddonCommandClient(serveFakeAddon(t, server))
	t.Cleanup(func() { _ = client.Close() })

	// 0x80/0xFF are invalid UTF-8: exactly where Go's per-byte replacement and
	// Rust's per-sequence replacement disagree. Base64 keeps the matcher's input
	// identical on both sides, so a binary banner cannot change corpus match
	// merely by crossing the transport.
	banner := []byte{'S', 'M', 'B', 0x80, 0xFF, 0x00, 'x'}

	_, err := client.MatchBanners(context.Background(), &netprobepb.BannerBatch{
		Observations: []*netprobepb.BannerObservation{{
			ObservationId: 1, Protocol: "smb", BannerBytes: banner,
		}},
	})
	require.NoError(t, err)

	var sent bannerMatchRequest
	require.NoError(t, json.Unmarshal(server.lastRequest.GetPayloadJson(), &sent))
	require.Equal(t, banner, sent.Observations[0].BannerBytes)
}

func TestMatchBannersSurfacesARefusal(t *testing.T) {
	server := &fakeAddonCommandServer{
		respond: func(*addonpb.RunCommandRequest) *addonpb.RunCommandResponse {
			return &addonpb.RunCommandResponse{Success: false, Message: "unsupported schema"}
		},
	}
	client := NewAddonCommandClient(serveFakeAddon(t, server))
	t.Cleanup(func() { _ = client.Close() })

	_, err := client.MatchBanners(context.Background(), &netprobepb.BannerBatch{})

	require.ErrorIs(t, err, ErrAddonCommandRefused)
	require.ErrorContains(t, err, "unsupported schema")
	// NOT reported as unavailable: the socket answered. Conflating the two would
	// let a genuine contract break hide as an un-upgraded netprobe forever.
	require.NotErrorIs(t, err, ErrAddonCommandUnavailable)
}

func TestMatchBannersReportsUnavailableWithoutASocket(t *testing.T) {
	client := NewAddonCommandClient(filepath.Join(t.TempDir(), "absent.sock"))

	_, err := client.MatchBanners(context.Background(), &netprobepb.BannerBatch{})

	require.ErrorIs(t, err, ErrAddonCommandUnavailable)
}

func TestSidecarFallsBackToIPCWhenTheCommandContractIsAbsent(t *testing.T) {
	sc := NewSidecar(SidecarConfig{})
	sc.SetAddonCommandClient(NewAddonCommandClient(filepath.Join(t.TempDir(), "absent.sock")))

	// No IPC client either, so the legacy path is reached and then blocks polling
	// for one. A cancelled context is how we observe that it got there at all.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := sc.MatchBanners(ctx, &netprobepb.BannerBatch{})

	// context.Canceled proves the legacy IPC wait was reached: the addon path
	// returns ErrAddonCommandUnavailable, so seeing THAT here would mean the
	// fallback never happened.
	require.ErrorIs(t, err, context.Canceled)
}

func keysOf(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}

	return keys
}
