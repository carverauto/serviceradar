//go:build camera_recording_fixture

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/pion/rtp"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
)

// The oracle is the one-source-per-normalized-profile contract. Protocol peers
// only supply media and receipts; admission, source connection, upload and
// executor cleanup all use production code. This does not launch the service
// main, enroll an agent, or exercise core storage or Membrane fan-out.
type runtimeLogger struct {
	logger.Logger
	output zerolog.Logger
}

func (l *runtimeLogger) Info() *zerolog.Event  { return l.output.Info() }
func (l *runtimeLogger) Warn() *zerolog.Event  { return l.output.Warn() }
func (l *runtimeLogger) Error() *zerolog.Event { return l.output.Error() }

type runtimeCamera struct {
	*syntheticCameraRTSPServer
	ctx       context.Context
	gate      chan struct{}
	described chan struct{}
	once      sync.Once
	opened    atomic.Int32
	closed    atomic.Int32
	playing   atomic.Int32
}

func (h *runtimeCamera) OnConnOpen(ctx *gortsplib.ServerHandlerOnConnOpenCtx) {
	h.opened.Add(1)
}

func (h *runtimeCamera) OnConnClose(*gortsplib.ServerHandlerOnConnCloseCtx) {
	h.closed.Add(1)
}

func (h *runtimeCamera) OnPlay(ctx *gortsplib.ServerHandlerOnPlayCtx) (*base.Response, error) {
	h.playing.Add(1)
	return h.syntheticCameraRTSPServer.OnPlay(ctx)
}

func (h *runtimeCamera) OnDescribe(ctx *gortsplib.ServerHandlerOnDescribeCtx) (*base.Response, *gortsplib.ServerStream, error) {
	h.once.Do(func() { close(h.described) })
	select {
	case <-h.gate:
	case <-h.ctx.Done():
		return &base.Response{StatusCode: base.StatusServiceUnavailable}, nil, h.ctx.Err()
	}
	return h.syntheticCameraRTSPServer.OnDescribe(ctx)
}

func runtimeAwait(t *testing.T, ctx context.Context, label string, ready func() bool) {
	t.Helper()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for !ready() {
		select {
		case <-ctx.Done():
			t.Fatalf("%s: %v", label, ctx.Err())
		case <-tick.C:
		}
	}
}

func runtimeInput(t *testing.T, name string) string {
	t.Helper()
	path, err := runfiles.Rlocation("_main/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func startRuntimeCamera(t *testing.T, ctx context.Context) (*runtimeCamera, string, func()) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "invented.h264")
	cmd := exec.CommandContext(ctx, runtimeInput(t, "third_party/membrane/media_test_tools/ffmpeg"),
		"-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10", "-frames:v", "10",
		"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-x264-params", "aud=1:keyint=1", "-f", "h264", path)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate synthetic media: %v: %s", err, out)
	}
	units := cameraFixtureUnits(t, readCameraFixture(t, path, 1_048_576))
	forma := &format.H264{PayloadTyp: 96, PacketizationMode: 1}
	for _, nalu := range units[0] {
		switch nalu[0] & 31 {
		case 7:
			forma.SPS = nalu
		case 8:
			forma.PPS = nalu
		}
	}
	media := &description.Media{Type: description.MediaTypeVideo, Formats: []format.Format{forma}}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	h := &runtimeCamera{syntheticCameraRTSPServer: &syntheticCameraRTSPServer{}, ctx: ctx, gate: make(chan struct{}), described: make(chan struct{})}
	server := &gortsplib.Server{Handler: h, RTSPAddress: listener.Addr().String(), Listen: func(string, string) (net.Listener, error) { return listener, nil }}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	stream := &gortsplib.ServerStream{Server: server, Desc: &description.Session{Medias: []*description.Media{media}}}
	if err := stream.Initialize(); err != nil {
		server.Close()
		t.Fatal(err)
	}
	h.stream = stream
	t.Cleanup(func() {
		server.Close()
		stream.Close()
	})
	encoder := &rtph264.Encoder{PayloadType: 96, PacketizationMode: 1, PayloadMaxSize: 500}
	if err := encoder.Init(); err != nil {
		t.Fatal(err)
	}
	var packets []*rtp.Packet
	for _, unit := range units {
		encoded, err := encoder.Encode(unit)
		if err != nil {
			t.Fatal(err)
		}
		packets = append(packets, encoded...)
	}
	// Send only when requested: a silent camera keeps the real plugin blocked
	// in its TCP read while cancellation and Close race with socket cleanup.
	var timestamp uint32
	var sequence uint16
	send := func() {
		for _, original := range packets {
			packet := *original
			packet.Timestamp = timestamp
			packet.SequenceNumber = sequence
			sequence++
			if err := stream.WritePacketRTP(media, &packet); err != nil {
				t.Fatal(err)
			}
			if packet.Marker {
				timestamp += 9000
			}
			time.Sleep(time.Millisecond)
		}
	}
	return h, "rtsp://" + listener.Addr().String() + "/synthetic-camera", send
}

type runtimeMediaPeer struct {
	proto.UnimplementedCameraMediaServiceServer
	opens          atomic.Int32
	chunks         chan *proto.MediaChunk
	pluginSnapshot func() PluginEngineSnapshot
	admissions     chan runtimeAdmission
}

type runtimeAdmission struct {
	relayID  string
	snapshot PluginEngineSnapshot
}

func (p *runtimeMediaPeer) OpenRelaySession(_ context.Context, req *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error) {
	p.opens.Add(1)
	if p.pluginSnapshot != nil {
		p.admissions <- runtimeAdmission{relayID: req.RelaySessionId, snapshot: p.pluginSnapshot()}
	}
	return &proto.OpenRelaySessionResponse{Accepted: true, MediaIngestId: "invented-" + req.RelaySessionId}, nil
}
func (p *runtimeMediaPeer) Heartbeat(context.Context, *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error) {
	return &proto.RelayHeartbeatAck{Accepted: true}, nil
}
func (p *runtimeMediaPeer) CloseRelaySession(context.Context, *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	return &proto.CloseRelaySessionResponse{Closed: true}, nil
}
func (p *runtimeMediaPeer) UploadMedia(stream grpc.ClientStreamingServer[proto.MediaChunk, proto.UploadMediaResponse]) error {
	var seq uint64
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		seq = chunk.Sequence
		select {
		case p.chunks <- chunk:
		case <-stream.Context().Done():
			return stream.Context().Err()
		}
	}
	return stream.SendAndClose(&proto.UploadMediaResponse{Received: true, LastSequence: seq})
}

// Only the response sink is synthetic; JSON commands pass through the owning
// production command handlers, rather than a second implementation of Start.
type runtimeCommandSink struct {
	grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse]
	result *proto.CommandResult
}

func (s *runtimeCommandSink) Send(req *proto.ControlStreamRequest) error {
	s.result = req.GetCommandResult()
	return nil
}
func runtimeCommand(t *testing.T, ctx context.Context, loop *PushLoop, payload any, stop bool) *proto.CommandResult {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	sink := &runtimeCommandSink{}
	sender := newControlStreamSender(sink)
	cmd := &proto.CommandRequest{CommandId: "invented-command", PayloadJson: body}
	if stop {
		loop.handleCameraRelayStop(ctx, cmd, sender)
	} else {
		loop.handleCameraRelayOpen(ctx, cmd, sender)
	}
	if sink.result == nil {
		t.Fatal("command returned no result")
	}
	return sink.result
}

func TestCameraSharedRuntime(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	for _, plugin := range []bool{false, true} {
		name := "native"
		if plugin {
			name = "wazero-axis"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
			defer cancel()
			camera, sourceURL, send := startRuntimeCamera(t, ctx)
			peer := &runtimeMediaPeer{chunks: make(chan *proto.MediaChunk, 128), admissions: make(chan runtimeAdmission, 16)}
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			server := grpc.NewServer()
			proto.RegisterCameraMediaServiceServer(server, peer)
			served := make(chan struct{})
			go func() { defer close(served); _ = server.Serve(listener) }()
			defer func() { server.Stop(); <-served }()
			gateway := agentgateway.NewGatewayClient(listener.Addr().String(), nil, logger.NewTestLogger())
			defer gateway.Disconnect()
			if err := gateway.Connect(ctx); err != nil {
				t.Fatal(err)
			}
			manager := newCameraRelayManager(gateway, logger.NewTestLogger())
			manager.uploadBatchSize = 1
			loop := &PushLoop{server: &Server{config: &ServerConfig{AgentID: "invented-agent"}}, gateway: gateway, cameraRelayManager: manager}
			payload := cameraRelayStartPayload{RelaySessionID: "invented-owner", CameraSourceID: " camera-a ", StreamProfileID: " main ", LeaseToken: "invented-lease", SourceURL: sourceURL, RTSPTransport: "tcp"}
			var plugins *PluginManager
			if plugin {
				plugins = runtimePlugins(t, ctx, sourceURL)
				peer.pluginSnapshot = plugins.Snapshot
				manager.pluginSourceFactory = func(ctx context.Context, spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
					return plugins.OpenCameraRelayStream(ctx, spec.PluginAssignmentID, spec)
				}
				payload.PluginAssignmentID = "invented-axis"
			}
			defer func() {
				cancel()
				cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
				defer done()
				for _, id := range []string{"invented-owner", "invented-conflict", "invented-replacement", "invented-other-camera", "invented-other-profile"} {
					if err := manager.Stop(cleanup, cameraRelayStopPayload{RelaySessionID: id}); err != nil && !errors.Is(err, errCameraRelaySessionNotFound) {
						t.Errorf("cleanup %s: %v", id, err)
					}
				}
				if plugins != nil {
					runtimeAwait(t, cleanup, "executors stopped before cache shutdown", func() bool { return plugins.Snapshot().ActiveExecutions == 0 })
					plugins.Stop()
				}
			}()
			owner := make(chan *proto.CommandResult, 1)
			go func() { owner <- runtimeCommand(t, ctx, loop, payload, false) }()
			select {
			case <-camera.described:
			case <-ctx.Done():
				t.Fatal("source never reached DESCRIBE")
			}
			conflict := payload
			conflict.RelaySessionID = "invented-conflict"
			conflict.CameraSourceID = "camera-a"
			conflict.StreamProfileID = "main"
			checkConflict := func(stage string) {
				t.Helper()
				before := peer.opens.Load()
				result := runtimeCommand(t, ctx, loop, conflict, false)
				if result.Success || result.Message != errCameraRelaySourceActive.Error() {
					t.Fatalf("%s conflict: %v", stage, result)
				}
				if peer.opens.Load() != before || camera.opened.Load()-camera.closed.Load() != 1 {
					t.Fatalf("%s opened another physical source or ingress", stage)
				}
			}
			checkConflict("opening")
			close(camera.gate)
			select {
			case result := <-owner:
				if !result.Success {
					t.Fatal(result)
				}
			case <-ctx.Done():
				t.Fatal("owner failed to start")
			}
			// Both connectors have completed PLAY before a chunk can reach ingress.
			runtimeAwait(t, ctx, "media reaches real upload", func() bool {
				send()
				select {
				case chunk := <-peer.chunks:
					return chunk.RelaySessionId == payload.RelaySessionID && bytes.Contains(chunk.Payload, []byte{0, 0, 0, 1})
				default:
					return false
				}
			})
			checkConflict("streaming")
			if result := runtimeCommand(t, ctx, loop, payload, false); result.Success || result.Message != errCameraRelaySessionExists.Error() {
				t.Fatalf("same ID: %v", result)
			}
			for _, other := range []struct{ id, camera, profile string }{
				{"invented-other-camera", "camera-b", "main"},
				{"invented-other-profile", "camera-a", "sub"},
			} {
				independent := payload
				independent.RelaySessionID = other.id
				independent.CameraSourceID = other.camera
				independent.StreamProfileID = other.profile
				if result := runtimeCommand(t, ctx, loop, independent, false); !result.Success {
					t.Fatalf("independent source: %v", result)
				}
			}
			runtimeAwait(t, ctx, "three independent physical sources", func() bool { return camera.playing.Load() == 3 })
			if camera.opened.Load()-camera.closed.Load() != 3 {
				t.Fatal("independent sources were not simultaneously live")
			}
			for _, id := range []string{"invented-other-camera", "invented-other-profile"} {
				if result := runtimeCommand(t, ctx, loop, cameraRelayStopPayload{RelaySessionID: id}, true); !result.Success {
					t.Fatalf("independent cleanup: %v", result)
				}
			}
			runtimeAwait(t, ctx, "independent sockets closed", func() bool { return camera.closed.Load() == 2 })
			if plugin {
				// Cancellation can race with real socket cleanup. A replacement
				// is legal only after the old executor and sockets are released.
				stopCtx, stopCancel := context.WithCancel(ctx)
				stopCancel()
				result := runtimeCommand(t, stopCtx, loop, cameraRelayStopPayload{RelaySessionID: payload.RelaySessionID}, true)
				if result.Success || result.Message != context.Canceled.Error() {
					t.Fatalf("bounded stop: %v", result)
				}
				result = runtimeCommand(t, ctx, loop, conflict, false)
				if result.Success {
					for {
						var admission runtimeAdmission
						select {
						case admission = <-peer.admissions:
						case <-ctx.Done():
							t.Fatal("replacement has no gateway admission receipt")
						}
						if admission.relayID != conflict.RelaySessionID {
							continue
						}
						if admission.snapshot.ActiveExecutions != 0 || admission.snapshot.OpenConnections != 0 {
							t.Fatalf("replacement admitted before prior cleanup: %+v", admission.snapshot)
						}
						break
					}
					if stopped := runtimeCommand(t, ctx, loop, cameraRelayStopPayload{RelaySessionID: conflict.RelaySessionID}, true); !stopped.Success {
						t.Fatal(stopped)
					}
				} else if result.Message != errCameraRelaySourceActive.Error() {
					t.Fatalf("replacement during cleanup: %v", result)
				}
			}
			result := runtimeCommand(t, ctx, loop, cameraRelayStopPayload{RelaySessionID: payload.RelaySessionID}, true)
			if !result.Success && result.Message != errCameraRelaySessionNotFound.Error() {
				t.Fatalf("stop: %v", result)
			}
			runtimeAwait(t, ctx, "physical sockets closed", func() bool { return camera.closed.Load() == camera.opened.Load() })
			if plugin && (plugins.Snapshot().ActiveExecutions != 0 || plugins.Snapshot().OpenConnections != 0) {
				t.Fatal("Stop returned with executor or sockets live")
			}
			conflict.RelaySessionID = "invented-replacement"
			if result := runtimeCommand(t, ctx, loop, conflict, false); !result.Success {
				t.Fatalf("replacement: %v", result)
			}
			if result := runtimeCommand(t, ctx, loop, cameraRelayStopPayload{RelaySessionID: conflict.RelaySessionID}, true); !result.Success {
				t.Fatalf("replacement cleanup: %v", result)
			}
			if plugin {
				runtimePluginClose(t, ctx, plugins, camera, sourceURL)
			}
			runtimeAwait(t, ctx, "all physical sources closed", func() bool { return camera.opened.Load() == camera.closed.Load() })
			t.Log("real source, ingress upload, normalized admission, owner survival and replacement verified")
		})
	}
}

func runtimePlugins(t *testing.T, ctx context.Context, sourceURL string) *PluginManager {
	t.Helper()
	probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":{"propertyList":{"ProdNbr":"invented-camera"}}}`))
	}))
	t.Cleanup(probe.Close)
	manager := NewPluginManager(ctx, PluginManagerConfig{Logger: &runtimeLogger{Logger: logger.NewTestLogger(), output: zerolog.New(os.Stdout)}, CacheDir: t.TempDir(), LocalStoreDir: t.TempDir()})
	wasm, err := os.ReadFile(runtimeInput(t, "build/wasm_plugins/axis_camera.wasm"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(manager.localStoreDir, "axis.wasm"), wasm, 0o600); err != nil {
		t.Fatal(err)
	}
	params, err := json.Marshal(map[string]any{"host": strings.TrimPrefix(probe.URL, "http://"), "scheme": "http", "timeout_ms": 3000})
	if err != nil {
		t.Fatal(err)
	}
	probeURL, err := url.Parse(probe.URL)
	if err != nil {
		t.Fatal(err)
	}
	rtspURL, err := url.Parse(sourceURL)
	if err != nil {
		t.Fatal(err)
	}
	probePort, err := strconv.Atoi(probeURL.Port())
	if err != nil {
		t.Fatal(err)
	}
	rtspPort, err := strconv.Atoi(rtspURL.Port())
	if err != nil {
		t.Fatal(err)
	}
	permissions, err := json.Marshal(map[string]any{"allowed_networks": []string{"127.0.0.1/32"}, "allowed_ports": []int{probePort, rtspPort}})
	if err != nil {
		t.Fatal(err)
	}
	manager.ApplyConfig(&proto.PluginConfig{EngineLimits: &proto.PluginEngineLimits{MaxConcurrent: 3}, Assignments: []*proto.PluginAssignmentConfig{{
		AssignmentId: "invented-axis", PluginId: "axis-camera-stream", Entrypoint: "stream_camera", Runtime: "wasi-preview1", Enabled: true, WasmObjectKey: "axis.wasm", TimeoutSec: 30,
		Capabilities: []string{"get_config", "log", "camera_media_stream", "http_request", "tcp_connect", "tcp_read", "tcp_write", "tcp_close"},
		ParamsJson:   params, PermissionsJson: permissions,
	}}})
	return manager
}

// Unlike the command test, this directly observes the public stream Close
// postcondition: no live executor/socket and immediate admission reuse.
func runtimePluginClose(t *testing.T, ctx context.Context, manager *PluginManager, camera *runtimeCamera, sourceURL string) {
	t.Helper()
	spec := cameraRelaySessionSpec{RelaySessionID: "invented-direct", CameraSourceID: "camera-direct", StreamProfileID: "main", SourceURL: sourceURL}
	before := camera.playing.Load()
	stream, err := manager.OpenCameraRelayStream(ctx, "invented-axis", spec)
	if err != nil {
		t.Fatal(err)
	}
	runtimeAwait(t, ctx, "plugin socket playing", func() bool { return camera.playing.Load() > before })
	if err := stream.Close(); err != nil {
		t.Fatal(err)
	}
	assertReleased := func() {
		t.Helper()
		snapshot := manager.Snapshot()
		if snapshot.ActiveExecutions != 0 || snapshot.OpenConnections != 0 {
			t.Fatalf("Close returned before executor/socket cleanup: %+v", snapshot)
		}
	}
	assertReleased()
	for _, cancelBeforeOpen := range []bool{true, false} {
		early, cancel := context.WithCancel(ctx)
		if cancelBeforeOpen {
			cancel()
		}
		stream, err := manager.OpenCameraRelayStream(early, "invented-axis", spec)
		cancel()
		if err != nil && !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
		if stream != nil {
			if err := stream.Close(); err != nil {
				t.Fatal(err)
			}
		}
		assertReleased()
	}
	stream, err = manager.OpenCameraRelayStream(ctx, "invented-axis", spec)
	if err != nil {
		t.Fatalf("slot not reusable: %v", err)
	}
	if err := stream.Close(); err != nil {
		t.Fatal(err)
	}
	assertReleased()
	t.Log("real Wazero Close and immediate-cancellation cleanup verified")
}
