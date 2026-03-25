package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

type fakeProtectRTSPReader struct {
	chunks [][]byte
	index  int
	err    error
}

func (r *fakeProtectRTSPReader) Read(buf []byte, _ time.Duration) (int, error) {
	if r.index >= len(r.chunks) {
		if r.err != nil {
			return 0, r.err
		}
		return 0, errors.New("eof")
	}

	chunk := r.chunks[r.index]
	r.index++
	copy(buf, chunk)
	return len(chunk), nil
}

func (r *fakeProtectRTSPReader) Close() error {
	return nil
}

func TestStreamProtectRTSPWritesMediaChunkThroughBridge(t *testing.T) {
	origSession := newProtectRTSPSession
	origOpen := openProtectMediaSessionF
	origWrite := writeProtectMediaF
	origHeartbeat := heartbeatProtectMediaF
	origClose := closeProtectMediaF
	origNow := protectNow
	t.Cleanup(func() {
		newProtectRTSPSession = origSession
		openProtectMediaSessionF = origOpen
		writeProtectMediaF = origWrite
		heartbeatProtectMediaF = origHeartbeat
		closeProtectMediaF = origClose
		protectNow = origNow
	})

	cfg := StreamConfig{
		Config: Config{
			CameraPluginConfig: sdk.CameraPluginConfig{
				Host:     "udm.local",
				Username: "protect",
				Password: "secret",
			},
			RTSPPort: 7447,
		},
	}

	var gotOpen protectMediaOpenRequest
	var gotMeta protectMediaChunkMetadata
	var gotPayload []byte
	var gotCloseReason string
	stopErr := errors.New("stop after first write")

	newProtectRTSPSession = func(_ StreamConfig, _ time.Duration, sourceURL string) (*protectRTSPSession, error) {
		if sourceURL != "rtsp://camera.local:7447/stream" {
			t.Fatalf("unexpected source URL %q", sourceURL)
		}
		return &protectRTSPSession{
			reader: &fakeProtectRTSPReader{
				chunks: [][]byte{
					mustInterleavedRTPFrame(t, 0, 1, 90000, []byte{0x65, 0x88, 0x84}),
				},
			},
			teardown: func() error { return nil },
		}, nil
	}
	openProtectMediaSessionF = func(req protectMediaOpenRequest) (*sdk.CameraMediaStream, error) {
		gotOpen = req
		return &sdk.CameraMediaStream{}, nil
	}
	writeProtectMediaF = func(_ *sdk.CameraMediaStream, meta protectMediaChunkMetadata, payload []byte) error {
		gotMeta = meta
		gotPayload = append([]byte(nil), payload...)
		return stopErr
	}
	heartbeatProtectMediaF = func(_ *sdk.CameraMediaStream, _ protectMediaHeartbeat) error {
		t.Fatalf("unexpected heartbeat")
		return nil
	}
	closeProtectMediaF = func(_ *sdk.CameraMediaStream, reason string) error {
		gotCloseReason = reason
		return nil
	}

	err := streamProtectRTSP(cfg, time.Second, "rtsp://camera.local:7447/stream")
	if !errors.Is(err, stopErr) {
		t.Fatalf("expected stop error, got %v", err)
	}

	if gotOpen.TrackID != "video" || gotOpen.Codec != "h264" || gotOpen.PayloadFormat != "annexb" {
		t.Fatalf("unexpected media open request %#v", gotOpen)
	}
	if gotMeta.Sequence != 1 {
		t.Fatalf("unexpected sequence %d", gotMeta.Sequence)
	}
	if !gotMeta.Keyframe {
		t.Fatalf("expected keyframe chunk")
	}
	if gotMeta.Codec != "h264" || gotMeta.PayloadFormat != "annexb" {
		t.Fatalf("unexpected media chunk metadata %#v", gotMeta)
	}
	if !bytes.HasPrefix(gotPayload, []byte{0x00, 0x00, 0x00, 0x01, 0x65}) {
		t.Fatalf("unexpected annexb payload %v", gotPayload)
	}
	if gotCloseReason != "rtsp media write failed" {
		t.Fatalf("unexpected close reason %q", gotCloseReason)
	}
}

func TestStreamProtectRTSPIdlesAfterRepeatedReadErrors(t *testing.T) {
	origSession := newProtectRTSPSession
	origOpen := openProtectMediaSessionF
	origWrite := writeProtectMediaF
	origHeartbeat := heartbeatProtectMediaF
	origClose := closeProtectMediaF
	origNow := protectNow
	t.Cleanup(func() {
		newProtectRTSPSession = origSession
		openProtectMediaSessionF = origOpen
		writeProtectMediaF = origWrite
		heartbeatProtectMediaF = origHeartbeat
		closeProtectMediaF = origClose
		protectNow = origNow
	})

	now := time.Unix(0, 0)
	protectNow = func() time.Time {
		now = now.Add(1100 * time.Millisecond)
		return now
	}

	var heartbeatCount int
	var closeReason string

	newProtectRTSPSession = func(_ StreamConfig, _ time.Duration, _ string) (*protectRTSPSession, error) {
		return &protectRTSPSession{
			reader:   &fakeProtectRTSPReader{err: errors.New("read failed")},
			teardown: func() error { return nil },
		}, nil
	}
	openProtectMediaSessionF = func(req protectMediaOpenRequest) (*sdk.CameraMediaStream, error) {
		return &sdk.CameraMediaStream{}, nil
	}
	writeProtectMediaF = func(_ *sdk.CameraMediaStream, _ protectMediaChunkMetadata, _ []byte) error {
		t.Fatalf("unexpected media write")
		return nil
	}
	heartbeatProtectMediaF = func(_ *sdk.CameraMediaStream, heartbeat protectMediaHeartbeat) error {
		heartbeatCount++
		if heartbeat.Sequence != 0 {
			t.Fatalf("unexpected heartbeat sequence %d", heartbeat.Sequence)
		}
		return nil
	}
	closeProtectMediaF = func(_ *sdk.CameraMediaStream, reason string) error {
		closeReason = reason
		return nil
	}

	err := streamProtectRTSP(StreamConfig{Config: Config{}}, time.Second, "rtsp://camera.local:7447/stream")
	if !errors.Is(err, errProtectRTSPStreamIdle) {
		t.Fatalf("expected idle error, got %v", err)
	}
	if heartbeatCount != 4 {
		t.Fatalf("expected 4 heartbeats before idle close, got %d", heartbeatCount)
	}
	if closeReason != "rtsp stream idle" {
		t.Fatalf("unexpected close reason %q", closeReason)
	}
}

func TestStreamProtectRTSPReturnsHeartbeatFailureOnIdle(t *testing.T) {
	origSession := newProtectRTSPSession
	origOpen := openProtectMediaSessionF
	origWrite := writeProtectMediaF
	origHeartbeat := heartbeatProtectMediaF
	origClose := closeProtectMediaF
	origNow := protectNow
	t.Cleanup(func() {
		newProtectRTSPSession = origSession
		openProtectMediaSessionF = origOpen
		writeProtectMediaF = origWrite
		heartbeatProtectMediaF = origHeartbeat
		closeProtectMediaF = origClose
		protectNow = origNow
	})

	now := time.Unix(0, 0)
	protectNow = func() time.Time {
		now = now.Add(1100 * time.Millisecond)
		return now
	}

	heartbeatErr := errors.New("heartbeat failed")
	var closeReason string

	newProtectRTSPSession = func(_ StreamConfig, _ time.Duration, _ string) (*protectRTSPSession, error) {
		return &protectRTSPSession{
			reader:   &fakeProtectRTSPReader{err: errors.New("read failed")},
			teardown: func() error { return nil },
		}, nil
	}
	openProtectMediaSessionF = func(req protectMediaOpenRequest) (*sdk.CameraMediaStream, error) {
		return &sdk.CameraMediaStream{}, nil
	}
	writeProtectMediaF = func(_ *sdk.CameraMediaStream, _ protectMediaChunkMetadata, _ []byte) error {
		t.Fatalf("unexpected media write")
		return nil
	}
	heartbeatProtectMediaF = func(_ *sdk.CameraMediaStream, _ protectMediaHeartbeat) error {
		return heartbeatErr
	}
	closeProtectMediaF = func(_ *sdk.CameraMediaStream, reason string) error {
		closeReason = reason
		return nil
	}

	err := streamProtectRTSP(StreamConfig{Config: Config{}}, time.Second, "rtsp://camera.local:7447/stream")
	if !errors.Is(err, heartbeatErr) {
		t.Fatalf("expected heartbeat error, got %v", err)
	}
	if closeReason != "rtsp heartbeat failed" {
		t.Fatalf("unexpected close reason %q", closeReason)
	}
}

func TestStreamProtectRTSPAcceptsRTSPSURLs(t *testing.T) {
	origSession := newProtectRTSPSession
	t.Cleanup(func() {
		newProtectRTSPSession = origSession
	})

	newProtectRTSPSession = func(cfg StreamConfig, timeout time.Duration, sourceURL string) (*protectRTSPSession, error) {
		if sourceURL != "rtsps://192.168.1.1:7441/example" {
			t.Fatalf("unexpected source url %q", sourceURL)
		}
		return nil, errors.New("dial attempted")
	}

	err := streamProtectRTSP(StreamConfig{}, time.Second, "rtsps://192.168.1.1:7441/example")
	if err == nil || err.Error() != "dial attempted" {
		t.Fatalf("unexpected error %v", err)
	}
}

func mustInterleavedRTPFrame(t *testing.T, channel uint8, sequence uint16, timestamp uint32, nal []byte) []byte {
	t.Helper()

	rtp := make([]byte, 12+len(nal))
	rtp[0] = 0x80
	rtp[1] = 0x80 | 96
	binary.BigEndian.PutUint16(rtp[2:4], sequence)
	binary.BigEndian.PutUint32(rtp[4:8], timestamp)
	binary.BigEndian.PutUint32(rtp[8:12], 1)
	copy(rtp[12:], nal)

	frame := make([]byte, 4+len(rtp))
	frame[0] = '$'
	frame[1] = channel
	binary.BigEndian.PutUint16(frame[2:4], uint16(len(rtp)))
	copy(frame[4:], rtp)
	return frame
}
