//go:build camera_recording_fixture

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	"github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
)

var (
	cameraRTSPRequest = flag.String("camera-rtsp-request", "", "synthetic capture request owned by the recording ExUnit test")
	cameraRTSPOutput  = flag.String("camera-rtsp-output", "", "captured receiver chunks for the recording ExUnit test")
)

type cameraRTSPCaptureRequest struct {
	Name   string
	Path   string
	Frames int
}

type cameraRTSPCapture struct {
	Name     string
	Chunks   []*cameraRelayChunk
	Terminal string
}

type syntheticCameraRTSPServer struct {
	mu          sync.RWMutex
	stream      *gortsplib.ServerStream
	connections chan *gortsplib.ServerConn
}

func (h *syntheticCameraRTSPServer) OnConnOpen(ctx *gortsplib.ServerHandlerOnConnOpenCtx) {
	select {
	case h.connections <- ctx.Conn:
	default:
		ctx.Conn.Close()
	}
}

func (h *syntheticCameraRTSPServer) OnDescribe(*gortsplib.ServerHandlerOnDescribeCtx) (*base.Response, *gortsplib.ServerStream, error) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return &base.Response{StatusCode: base.StatusOK}, h.stream, nil
}

func (h *syntheticCameraRTSPServer) OnSetup(*gortsplib.ServerHandlerOnSetupCtx) (*base.Response, *gortsplib.ServerStream, error) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return &base.Response{StatusCode: base.StatusOK}, h.stream, nil
}

func (*syntheticCameraRTSPServer) OnPlay(*gortsplib.ServerHandlerOnPlayCtx) (*base.Response, error) {
	return &base.Response{StatusCode: base.StatusOK}, nil
}

// This declared test-binary tool reaches the private production RTSP receiver.
// The owning ExUnit target supplies freshly generated media and tests recording
// behavior against the received bytes; no live camera or protocol stub is used.
func TestCameraRTSPRecordingCapture(t *testing.T) {
	if *cameraRTSPRequest == "" || *cameraRTSPOutput == "" {
		t.Fatal("run through //elixir/serviceradar_core_elx:recording_rtsp_tests")
	}
	var requests []cameraRTSPCaptureRequest
	if err := json.Unmarshal(readCameraFixture(t, *cameraRTSPRequest, 16_384), &requests); err != nil {
		t.Fatal(err)
	}
	if len(requests) == 0 || len(requests) > 4 {
		t.Fatal("capture requires one to four bounded synthetic connections")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	handler := &syntheticCameraRTSPServer{connections: make(chan *gortsplib.ServerConn, 4)}
	server := &gortsplib.Server{
		Handler:        handler,
		RTSPAddress:    listener.Addr().String(),
		Listen:         func(string, string) (net.Listener, error) { return listener, nil },
		ReadTimeout:    2 * time.Second,
		WriteTimeout:   2 * time.Second,
		IdleTimeout:    3 * time.Second,
		WriteQueueSize: 256,
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(server.Close)
	url := "rtsp://" + listener.Addr().String() + "/synthetic-camera"
	var captures []cameraRTSPCapture
	for _, request := range requests {
		captures = append(captures, captureCameraRTSP(t, server, handler, url, request))
	}
	output, err := json.Marshal(captures)
	if err != nil {
		t.Fatal(err)
	}
	if len(output) > 8_388_608 {
		t.Fatal("synthetic capture output exceeds bound")
	}
	if err := os.WriteFile(*cameraRTSPOutput, output, 0o600); err != nil {
		t.Fatal(err)
	}
}

func captureCameraRTSP(t *testing.T, server *gortsplib.Server, handler *syntheticCameraRTSPServer, url string, request cameraRTSPCaptureRequest) cameraRTSPCapture {
	t.Helper()
	units := cameraFixtureUnits(t, readCameraFixture(t, request.Path, 1_048_576))
	if request.Frames < 2 || request.Frames > 90 || request.Frames > len(units) {
		t.Fatal("invalid synthetic frame count")
	}
	formatH264 := &format.H264{PayloadTyp: 96, PacketizationMode: 1}
	for _, nalu := range units[0] {
		switch nalu[0] & 0x1f {
		case 7:
			formatH264.SPS = nalu
		case 8:
			formatH264.PPS = nalu
		}
	}
	if len(formatH264.SPS) == 0 || len(formatH264.PPS) == 0 {
		t.Fatal("fixture must begin with codec initialization")
	}
	media := &description.Media{Type: description.MediaTypeVideo, Formats: []format.Format{formatH264}}
	stream := &gortsplib.ServerStream{Server: server, Desc: &description.Session{Medias: []*description.Media{media}}}
	if err := stream.Initialize(); err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	handler.mu.Lock()
	handler.stream = stream
	handler.mu.Unlock()
	receiver, err := newRTSPCameraRelayStream(cameraRelaySessionSpec{SourceURL: url, RTSPTransport: "tcp"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = receiver.Close() }()
	var connection *gortsplib.ServerConn
	select {
	case connection = <-handler.connections:
	case <-time.After(2 * time.Second):
		t.Fatal("RTSP connection was not observed")
	}
	defer connection.Close()
	encoder := &rtph264.Encoder{PayloadType: 96, PacketizationMode: 1, PayloadMaxSize: 500}
	if err := encoder.Init(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	capture := cameraRTSPCapture{Name: request.Name}
	for index, unit := range units[:request.Frames] {
		packets, err := encoder.Encode(unit)
		if err != nil {
			t.Fatal(err)
		}
		for _, packet := range packets {
			// Cross a 32-bit RTP wrap while the production receiver establishes its
			// own relative 90kHz clock. Neither PTS nor sequence is rewritten below.
			packet.Timestamp = uint32(0xffffdcd7) + uint32(index*6_000)
			if err := stream.WritePacketRTP(media, packet); err != nil {
				t.Fatal(err)
			}
		}
		chunk, err := receiver.Recv(ctx)
		if err != nil {
			t.Fatalf("%s frame %d: %v", request.Name, index, err)
		}
		want, err := unit.Marshal()
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(chunk.Payload, want) {
			t.Fatalf("%s frame %d changed AnnexB NAL payload", request.Name, index)
		}
		if chunk.PTS != int64(index*6_000) || chunk.DTS != chunk.PTS || chunk.Sequence != uint64(index+1) {
			t.Fatalf("unexpected receiver timebase/sequence: pts=%d dts=%d sequence=%d frame=%d", chunk.PTS, chunk.DTS, chunk.Sequence, index)
		}
		capture.Chunks = append(capture.Chunks, chunk)
	}
	connection.Close()
	_, terminal := receiver.Recv(ctx)
	if terminal == nil || errors.Is(terminal, context.DeadlineExceeded) || errors.Is(terminal, context.Canceled) {
		t.Fatalf("receiver did not report the forced source loss: %v", terminal)
	}
	capture.Terminal = terminal.Error()
	return capture
}

func readCameraFixture(t *testing.T, path string, limit int64) []byte {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(data)) > limit {
		t.Fatal("synthetic input exceeds byte bound")
	}
	return data
}

func cameraFixtureUnits(t *testing.T, data []byte) []h264.AnnexB {
	t.Helper()
	aud := []byte{0, 0, 0, 1, 9}
	parts := bytes.Split(data, aud)
	if len(parts[0]) != 0 || len(parts) < 3 || len(parts) > 91 {
		t.Fatal("invalid bounded synthetic AnnexB fixture")
	}
	units := make([]h264.AnnexB, 0, len(parts)-1)
	for _, part := range parts[1:] {
		var unit h264.AnnexB
		if err := unit.Unmarshal(append(bytes.Clone(aud), part...)); err != nil {
			t.Fatal(err)
		}
		units = append(units, unit)
	}
	return units
}
