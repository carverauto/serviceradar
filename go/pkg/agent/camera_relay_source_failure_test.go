package agent

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

// Invented stream credentials. The failure reason the agent reports must never
// carry any of them, whatever the camera answered.
const (
	sourceFailureTestUser  = "viewer"
	sourceFailureTestPass  = "hunter2"
	sourceFailureTestAlias = "AbCdEf0123TokenXyz"
)

// fakeRTSPCamera answers every OPTIONS with 200 and every DESCRIBE with the
// configured response, speaking real RTSP over a real TCP socket so the agent's
// default gortsplib source produces the error it would get from a camera.
type fakeRTSPCamera struct {
	listener net.Listener
	describe func(cseq string) string
	closeAll bool
}

func startFakeRTSPCamera(t *testing.T, camera *fakeRTSPCamera) string {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	camera.listener = listener
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go camera.serve(conn)
		}
	}()

	return listener.Addr().String()
}

func (c *fakeRTSPCamera) serve(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	if c.closeAll {
		return
	}

	reader := textproto.NewReader(bufio.NewReader(conn))
	for {
		requestLine, err := reader.ReadLine()
		if err != nil {
			return
		}
		header, err := reader.ReadMIMEHeader()
		if err != nil {
			return
		}
		cseq := header.Get("Cseq")
		method := strings.SplitN(requestLine, " ", 2)[0]

		var response string
		switch method {
		case "OPTIONS":
			response = "RTSP/1.0 200 OK\r\nCSeq: " + cseq + "\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n"
		case "DESCRIBE":
			response = c.describe(cseq)
		default:
			response = "RTSP/1.0 405 Method Not Allowed\r\nCSeq: " + cseq + "\r\n\r\n"
		}
		if _, err := conn.Write([]byte(response)); err != nil {
			return
		}
	}
}

func rtspStatus(code int, text string, extra string) func(string) string {
	return func(cseq string) string {
		return fmt.Sprintf("RTSP/1.0 %d %s\r\nCSeq: %s\r\n%s\r\n", code, text, cseq, extra)
	}
}

func audioOnlySDP(cseq string) string {
	sdp := "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=cam\r\nt=0 0\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n"
	return fmt.Sprintf("RTSP/1.0 200 OK\r\nCSeq: %s\r\nContent-Type: application/sdp\r\nContent-Length: %d\r\n\r\n%s", cseq, len(sdp), sdp)
}

// startRelayAgainstSource runs one relay startup through the manager with its
// default source factory and returns the CloseRelaySessionRequest the agent sent.
func startRelayAgainstSource(t *testing.T, sessionID, sourceURL string) (string, string, error) {
	t.Helper()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())

	_, startErr := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  sessionID,
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
		SourceURL:       sourceURL,
		RTSPTransport:   "tcp",
	})

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for the relay close after source startup failure")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()
	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}

	return gateway.closeRequests[0].GetReason(), gateway.closeRequests[0].GetFailureReason(), startErr
}

func TestCameraRelaySourceFailureReasonFromRealRTSPSocket(t *testing.T) {
	t.Parallel()

	closedListener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	closedAddr := closedListener.Addr().String()
	_ = closedListener.Close()

	basicChallenge := "WWW-Authenticate: Basic realm=\"camera\"\r\n"

	tests := []struct {
		name      string
		camera    *fakeRTSPCamera
		addr      string
		wantClass string
	}{
		{"nothing listening", nil, closedAddr, cameraRelayFailureConnectRefused},
		{"wrong password", &fakeRTSPCamera{describe: rtspStatus(401, "Unauthorized", basicChallenge)}, "", cameraRelayFailureAuthentication},
		{"unknown stream alias", &fakeRTSPCamera{describe: rtspStatus(404, "Not Found", "")}, "", cameraRelayFailureNotFound},
		{"camera drops the connection", &fakeRTSPCamera{closeAll: true}, "", cameraRelayFailureUpstreamClosed},
		{"audio only stream", &fakeRTSPCamera{describe: audioOnlySDP}, "", cameraRelayFailureNoVideoTrack},
	}

	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			addr := tt.addr
			if tt.camera != nil {
				addr = startFakeRTSPCamera(t, tt.camera)
			}
			sourceURL := fmt.Sprintf("rtsp://%s:%s@%s/%s?enableSrtp", sourceFailureTestUser, sourceFailureTestPass, addr, sourceFailureTestAlias)

			reason, failure, startErr := startRelayAgainstSource(t, fmt.Sprintf("relay-real-source-%d", i), sourceURL)
			t.Logf("close reason=%q failure_reason=%q start error=%v", reason, failure, startErr)

			if startErr == nil {
				t.Fatal("expected the relay start to fail")
			}
			if reason != cameraRelayReasonSourceStartFail {
				t.Fatalf("close reason = %q, want %q", reason, cameraRelayReasonSourceStartFail)
			}
			if !strings.HasPrefix(failure, tt.wantClass+": ") {
				t.Fatalf("failure_reason = %q, want class %q", failure, tt.wantClass)
			}
			for _, leaked := range []string{sourceFailureTestUser, sourceFailureTestPass, sourceFailureTestAlias, "enableSrtp"} {
				if strings.Contains(failure, leaked) || strings.Contains(startErr.Error(), leaked) {
					t.Fatalf("credential material %q leaked: failure_reason=%q start error=%q", leaked, failure, startErr)
				}
			}
		})
	}
}
