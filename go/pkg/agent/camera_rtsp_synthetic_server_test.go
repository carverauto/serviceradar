package agent

import (
	"net"
	"sync"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
)

// syntheticCameraRTSPServer is a loopback RTSP camera built on gortsplib's own
// server. Tests publish invented H264 into its stream and drive the production
// RTSP receiver against it; no live camera is involved.
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

func startSyntheticCameraRTSP(t *testing.T, disableSenderReports bool) (*gortsplib.Server, *syntheticCameraRTSPServer, string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	handler := &syntheticCameraRTSPServer{connections: make(chan *gortsplib.ServerConn, 4)}
	server := &gortsplib.Server{
		Handler:                  handler,
		RTSPAddress:              listener.Addr().String(),
		Listen:                   func(string, string) (net.Listener, error) { return listener, nil },
		ReadTimeout:              2 * time.Second,
		WriteTimeout:             2 * time.Second,
		IdleTimeout:              3 * time.Second,
		WriteQueueSize:           256,
		DisableRTCPSenderReports: disableSenderReports,
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(server.Close)
	return server, handler, "rtsp://" + listener.Addr().String() + "/synthetic-camera"
}
