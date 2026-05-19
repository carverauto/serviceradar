/*
 * Copyright 2025 Carver Automation Corporation.
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

package agent

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
	goproto "google.golang.org/protobuf/proto"
)

const (
	testDesktopMediaSessionID = "desktop-media-session-1"
	testDesktopMediaID        = "media-session-1"
	testDesktopMediaIngestID  = "media-ingest-1"
	testDesktopMediaAgentID   = "agent-1"
	testDesktopMediaGatewayID = "gateway-1"
	testDesktopMediaTargetID  = "target-1"
	testDesktopMediaRouteID   = "route-1"
	testDesktopMediaLease     = "lease-1"
)

var (
	errFakeDesktopMediaStreamUnavailable = errors.New("stream unavailable")
	errFakeDesktopMediaCloseFailed       = errors.New("close failed")
)

func TestDesktopMediaGatewaySenderOpensAndSendsFrames(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	gateway := &fakeDesktopMediaGateway{
		openResp: &proto.OpenDesktopMediaSessionResponse{
			Accepted:           true,
			MediaIngestId:      testDesktopMediaIngestID,
			MediaSessionId:     testDesktopMediaID,
			MaxChunkBytes:      32,
			InitialCreditBytes: 64,
		},
		stream: stream,
	}

	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}

	frame := remoteaccess.DesktopMediaFrame{
		SessionBindingID:  testDesktopMediaSessionID,
		MediaSessionID:    testDesktopMediaID,
		Sequence:          7,
		TimestampUnixNano: 1_778_000_000_000,
		Width:             10,
		Height:            10,
		PayloadFamily:     remoteaccess.DesktopMediaPayloadTile,
		Encoding:          "raw_rgba",
		Metadata:          []byte{1, 2},
		Payload:           []byte{3, 4, 5},
		Flags:             remoteaccess.DesktopMediaFlagKeyframe,
	}
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); err != nil {
		t.Fatalf("SendDesktopMediaFrame returned error: %v", err)
	}

	if gateway.openReq.GetDesktopSessionId() != testDesktopMediaSessionID ||
		gateway.openReq.GetMediaSessionId() != testDesktopMediaID ||
		gateway.openReq.GetLeaseToken() != testDesktopMediaLease {
		t.Fatalf("open request = %#v", gateway.openReq)
	}

	msg := stream.sent[0]
	chunk := msg.GetFrame()
	if chunk == nil {
		t.Fatal("sent message did not contain frame chunk")
	}
	if chunk.GetDesktopSessionId() != testDesktopMediaSessionID ||
		chunk.GetMediaSessionId() != testDesktopMediaID ||
		chunk.GetMediaIngestId() != testDesktopMediaIngestID ||
		chunk.GetAgentId() != testDesktopMediaAgentID ||
		chunk.GetSequence() != 7 ||
		chunk.GetPayloadFamily() != remoteaccess.DesktopMediaPayloadTile ||
		chunk.GetFlags() != uint32(remoteaccess.DesktopMediaFlagKeyframe) {
		t.Fatalf("frame chunk = %#v", chunk)
	}
}

func TestDesktopMediaGatewaySenderConsumesFrameBytesBeforeReturn(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		&fakeDesktopMediaGateway{
			openResp: acceptedDesktopMediaOpenResponse(),
			stream:   stream,
		},
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}
	t.Cleanup(func() { _ = sender.Close(context.Background(), "test done") })

	metadata := []byte{1, 2}
	payload := []byte{3, 4, 5}
	frame := remoteaccess.DesktopMediaFrame{
		SessionBindingID:  testDesktopMediaSessionID,
		MediaSessionID:    testDesktopMediaID,
		Sequence:          7,
		TimestampUnixNano: 1_778_000_000_000,
		Width:             10,
		Height:            10,
		PayloadFamily:     remoteaccess.DesktopMediaPayloadTile,
		Encoding:          "raw_rgba",
		Metadata:          metadata,
		Payload:           payload,
	}
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); err != nil {
		t.Fatalf("SendDesktopMediaFrame returned error: %v", err)
	}
	clearBytes(metadata)
	clearBytes(payload)

	chunk := stream.sent[0].GetFrame()
	if chunk == nil {
		t.Fatal("sent message did not contain frame chunk")
	}
	if got := chunk.GetMetadata(); len(got) != 2 || got[0] != 1 || got[1] != 2 {
		t.Fatalf("sent metadata = %v, want [1 2]", got)
	}
	if got := chunk.GetPayload(); len(got) != 3 || got[0] != 3 || got[1] != 4 || got[2] != 5 {
		t.Fatalf("sent payload = %v, want [3 4 5]", got)
	}
}

func TestDesktopMediaGatewaySenderRoutesAcks(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	ackCh := make(chan remoteaccess.DesktopMediaAck, 1)
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		&fakeDesktopMediaGateway{
			openResp: acceptedDesktopMediaOpenResponse(),
			stream:   stream,
		},
		testDesktopMediaGatewaySenderConfig(),
		func(_ context.Context, ack remoteaccess.DesktopMediaAck) error {
			ackCh <- ack
			return nil
		},
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}
	t.Cleanup(func() { _ = sender.Close(context.Background(), "test done") })

	stream.recv <- &proto.DesktopMediaServerMessage{
		Message: &proto.DesktopMediaServerMessage_Ack{
			Ack: &proto.DesktopMediaAck{
				DesktopSessionId:     testDesktopMediaSessionID,
				MediaSessionId:       testDesktopMediaID,
				MediaIngestId:        testDesktopMediaIngestID,
				GatewayId:            testDesktopMediaGatewayID,
				LastAcceptedSequence: 9,
				CreditBytes:          1024,
				QualityLevel:         1,
				Pause:                true,
				CloseReason:          " gateway\nclosed\t",
			},
		},
	}

	select {
	case ack := <-ackCh:
		if ack.SessionBindingID != testDesktopMediaSessionID ||
			ack.MediaSessionID != testDesktopMediaID ||
			ack.LastAcceptedSeq != 9 ||
			ack.CreditBytes != 1024 ||
			ack.QualityLevel != remoteaccess.DesktopMediaQualityLow ||
			ack.CloseReason != "gateway closed" ||
			!ack.Pause {
			t.Fatalf("ack = %#v", ack)
		}
	case <-sender.RecvErr():
		t.Fatal("sender returned receive error before ack")
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for desktop media ack")
	}
}

func TestDesktopMediaGatewaySenderRejectsInvalidAcksBeforeHandler(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	called := make(chan struct{}, 1)
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		&fakeDesktopMediaGateway{
			openResp: acceptedDesktopMediaOpenResponse(),
			stream:   stream,
		},
		testDesktopMediaGatewaySenderConfig(),
		func(context.Context, remoteaccess.DesktopMediaAck) error {
			called <- struct{}{}
			return nil
		},
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}

	stream.recv <- &proto.DesktopMediaServerMessage{
		Message: &proto.DesktopMediaServerMessage_Ack{
			Ack: &proto.DesktopMediaAck{
				DesktopSessionId:     "other-session",
				MediaSessionId:       testDesktopMediaID,
				LastAcceptedSequence: 9,
				CreditBytes:          1024,
			},
		},
	}

	select {
	case err := <-sender.RecvErr():
		if !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaAck) {
			t.Fatalf("recv error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaAck)
		}
	case <-called:
		t.Fatal("ack handler was called for invalid ack")
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for invalid ack error")
	}
}

func TestDesktopMediaGatewaySenderRejectsInboundAckBindingMismatches(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*proto.DesktopMediaAck)
	}{
		{
			name: "media ingest mismatch",
			mutate: func(ack *proto.DesktopMediaAck) {
				ack.MediaIngestId = "other-ingest"
			},
		},
		{
			name: "gateway mismatch",
			mutate: func(ack *proto.DesktopMediaAck) {
				ack.GatewayId = "other-gateway"
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			stream := newFakeDesktopMediaStream()
			called := make(chan struct{}, 1)
			sender, err := newDesktopMediaGatewaySender(
				context.Background(),
				&fakeDesktopMediaGateway{
					openResp: acceptedDesktopMediaOpenResponse(),
					stream:   stream,
				},
				testDesktopMediaGatewaySenderConfig(),
				func(context.Context, remoteaccess.DesktopMediaAck) error {
					called <- struct{}{}
					return nil
				},
			)
			if err != nil {
				t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
			}

			ack := validDesktopMediaProtoAck()
			tc.mutate(ack)
			stream.recv <- &proto.DesktopMediaServerMessage{
				Message: &proto.DesktopMediaServerMessage_Ack{Ack: ack},
			}

			select {
			case err := <-sender.RecvErr():
				if !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaAck) {
					t.Fatalf("recv error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaAck)
				}
			case <-called:
				t.Fatal("ack handler was called for mismatched ack")
			case <-time.After(5 * time.Second):
				t.Fatal("timed out waiting for invalid ack error")
			}
		})
	}
}

func TestDesktopMediaGatewaySenderRejectsInvalidFrames(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		&fakeDesktopMediaGateway{
			openResp: &proto.OpenDesktopMediaSessionResponse{
				Accepted:       true,
				MediaIngestId:  testDesktopMediaIngestID,
				MediaSessionId: testDesktopMediaID,
				MaxChunkBytes:  4,
			},
			stream: stream,
		},
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}
	t.Cleanup(func() { _ = sender.Close(context.Background(), "test done") })

	frame := remoteaccess.DesktopMediaFrame{
		SessionBindingID: testDesktopMediaSessionID,
		MediaSessionID:   testDesktopMediaID,
		Payload:          []byte{1, 2, 3, 4, 5},
	}
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("oversized frame error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	frame.Payload = nil
	frame.MediaSessionID = "other-media"
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("media mismatch error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	frame.MediaSessionID = testDesktopMediaID
	frame.PayloadFamily = "unknown"
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("payload-family error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	frame.PayloadFamily = remoteaccess.DesktopMediaPayloadTile
	frame.Width = remoteaccess.DesktopMaxWidth + 1
	frame.Height = 1
	if err := sender.SendDesktopMediaFrame(context.Background(), frame); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("dimension error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	if len(stream.sent) != 0 {
		t.Fatalf("invalid frame was forwarded: %#v", stream.sent)
	}
}

func TestDesktopMediaGatewaySenderRejectsOversizedChunkNegotiation(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	cfg := testDesktopMediaGatewaySenderConfig()
	cfg.RequestedMaxChunkBytes = remoteaccess.DesktopMaxFrameData + 1
	gateway := &fakeDesktopMediaGateway{
		openResp: acceptedDesktopMediaOpenResponse(),
		stream:   stream,
	}
	if _, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		cfg,
		nil,
	); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("requested max chunk error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if gateway.openReq != nil {
		t.Fatalf("gateway open called for invalid config: %#v", gateway.openReq)
	}

	gateway = &fakeDesktopMediaGateway{
		openResp: &proto.OpenDesktopMediaSessionResponse{
			Accepted:       true,
			MediaIngestId:  testDesktopMediaIngestID,
			MediaSessionId: testDesktopMediaID,
			MaxChunkBytes:  remoteaccess.DesktopMaxFrameData + 1,
		},
		stream: stream,
	}
	if _, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("gateway max chunk error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if gateway.closeCount != 1 ||
		gateway.closeReq.GetMediaSessionId() != testDesktopMediaID ||
		gateway.closeReq.GetMediaIngestId() != testDesktopMediaIngestID {
		t.Fatalf("gateway close after max chunk rejection = count %d request %#v", gateway.closeCount, gateway.closeReq)
	}
}

func TestDesktopMediaGatewaySenderClosesAcceptedSessionWhenMediaBindingMismatches(t *testing.T) {
	t.Parallel()

	gateway := &fakeDesktopMediaGateway{
		openResp: &proto.OpenDesktopMediaSessionResponse{
			Accepted:       true,
			MediaIngestId:  testDesktopMediaIngestID,
			MediaSessionId: "other-media",
			MaxChunkBytes:  remoteaccess.DesktopMediaDefaultMaxChunkBytes,
		},
		stream: newFakeDesktopMediaStream(),
	}

	if _, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("media binding error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if gateway.closeCount != 1 ||
		gateway.closeReq.GetMediaSessionId() != "other-media" ||
		gateway.closeReq.GetMediaIngestId() != testDesktopMediaIngestID ||
		gateway.closeReq.GetReason() == "" {
		t.Fatalf("gateway close after media mismatch = count %d request %#v", gateway.closeCount, gateway.closeReq)
	}
}

func TestDesktopMediaGatewaySenderClosesAcceptedSessionWhenMediaIngestMissing(t *testing.T) {
	t.Parallel()

	gateway := &fakeDesktopMediaGateway{
		openResp: &proto.OpenDesktopMediaSessionResponse{
			Accepted:       true,
			MediaSessionId: testDesktopMediaID,
			MaxChunkBytes:  remoteaccess.DesktopMediaDefaultMaxChunkBytes,
		},
		stream: newFakeDesktopMediaStream(),
	}

	if _, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	); !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
		t.Fatalf("missing ingest error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if gateway.closeCount != 1 ||
		gateway.closeReq.GetMediaSessionId() != testDesktopMediaID ||
		gateway.closeReq.GetMediaIngestId() != "" ||
		gateway.closeReq.GetReason() == "" {
		t.Fatalf("gateway close after missing ingest = count %d request %#v", gateway.closeCount, gateway.closeReq)
	}
}

func TestDesktopMediaGatewaySenderClosesAcceptedSessionWhenStreamOpenFails(t *testing.T) {
	t.Parallel()

	gateway := &fakeDesktopMediaGateway{
		openResp:  acceptedDesktopMediaOpenResponse(),
		streamErr: errFakeDesktopMediaStreamUnavailable,
	}

	_, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if !errors.Is(err, errFakeDesktopMediaStreamUnavailable) {
		t.Fatalf("stream open error = %v, want %v", err, errFakeDesktopMediaStreamUnavailable)
	}
	if gateway.closeCount != 1 {
		t.Fatalf("gateway close count = %d, want 1", gateway.closeCount)
	}
	if gateway.closeReq.GetDesktopSessionId() != testDesktopMediaSessionID ||
		gateway.closeReq.GetMediaSessionId() != testDesktopMediaID ||
		gateway.closeReq.GetMediaIngestId() != testDesktopMediaIngestID ||
		gateway.closeReq.GetReason() == "" {
		t.Fatalf("gateway close request = %#v", gateway.closeReq)
	}
}

func TestDesktopMediaGatewaySenderClosesAcceptedSessionWhenStreamIsNil(t *testing.T) {
	t.Parallel()

	gateway := &fakeDesktopMediaGateway{
		openResp: acceptedDesktopMediaOpenResponse(),
	}

	_, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if !errors.Is(err, errDesktopMediaSessionRejected) {
		t.Fatalf("nil stream error = %v, want %v", err, errDesktopMediaSessionRejected)
	}
	if gateway.closeCount != 1 {
		t.Fatalf("gateway close count = %d, want 1", gateway.closeCount)
	}
	if gateway.closeReq.GetDesktopSessionId() != testDesktopMediaSessionID ||
		gateway.closeReq.GetMediaSessionId() != testDesktopMediaID ||
		gateway.closeReq.GetMediaIngestId() != testDesktopMediaIngestID ||
		gateway.closeReq.GetReason() == "" {
		t.Fatalf("gateway close request = %#v", gateway.closeReq)
	}
}

func TestDesktopMediaGatewaySenderReturnsCleanupErrorWhenAcceptedSessionCloseFails(t *testing.T) {
	t.Parallel()

	gateway := &fakeDesktopMediaGateway{
		openResp:  acceptedDesktopMediaOpenResponse(),
		streamErr: errFakeDesktopMediaStreamUnavailable,
		closeErr:  errFakeDesktopMediaCloseFailed,
	}

	_, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if !errors.Is(err, errFakeDesktopMediaStreamUnavailable) || !errors.Is(err, errFakeDesktopMediaCloseFailed) {
		t.Fatalf("stream cleanup error = %v, want stream and close errors", err)
	}
	if gateway.closeCount != 1 {
		t.Fatalf("gateway close count = %d, want 1", gateway.closeCount)
	}
}

func TestDesktopMediaGatewaySenderCloseIsIdempotent(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	gateway := &fakeDesktopMediaGateway{
		openResp: acceptedDesktopMediaOpenResponse(),
		stream:   stream,
	}
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}

	if err := sender.Close(context.Background(), "operator"); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if err := sender.Close(context.Background(), "duplicate"); err != nil {
		t.Fatalf("second Close returned error: %v", err)
	}
	if gateway.closeCount != 1 || gateway.closeReq.GetReason() != "operator" {
		t.Fatalf("gateway close count = %d request = %#v", gateway.closeCount, gateway.closeReq)
	}
	if stream.closeSendCount != 1 {
		t.Fatalf("stream CloseSend count = %d, want 1", stream.closeSendCount)
	}

	err = sender.SendDesktopMediaFrame(context.Background(), remoteaccess.DesktopMediaFrame{
		SessionBindingID: testDesktopMediaSessionID,
		MediaSessionID:   testDesktopMediaID,
		PayloadFamily:    remoteaccess.DesktopMediaPayloadTile,
		Width:            1,
		Height:           1,
	})
	if !errors.Is(err, errDesktopMediaStreamClosed) {
		t.Fatalf("post-close send error = %v, want %v", err, errDesktopMediaStreamClosed)
	}
}

func TestDesktopMediaGatewaySenderNormalizesCloseReason(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	gateway := &fakeDesktopMediaGateway{
		openResp: acceptedDesktopMediaOpenResponse(),
		stream:   stream,
	}
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		gateway,
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}

	reason := " operator\nclosed\t" + strings.Repeat("x", remoteaccess.DesktopMediaMaxCloseReason)
	if err := sender.Close(context.Background(), reason); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}

	closeMsg := stream.sent[0].GetClose()
	if closeMsg == nil {
		t.Fatal("sent message did not contain close")
	}
	if strings.ContainsAny(closeMsg.GetReason(), "\n\t") ||
		strings.ContainsAny(gateway.closeReq.GetReason(), "\n\t") {
		t.Fatalf("close reasons were not normalized: stream=%q gateway=%q", closeMsg.GetReason(), gateway.closeReq.GetReason())
	}
	if len(closeMsg.GetReason()) > remoteaccess.DesktopMediaMaxCloseReason ||
		len(gateway.closeReq.GetReason()) > remoteaccess.DesktopMediaMaxCloseReason {
		t.Fatalf("close reasons were not capped: stream=%d gateway=%d", len(closeMsg.GetReason()), len(gateway.closeReq.GetReason()))
	}
}

func TestDesktopMediaGatewaySenderNormalizesInboundCloseReason(t *testing.T) {
	t.Parallel()

	stream := newFakeDesktopMediaStream()
	sender, err := newDesktopMediaGatewaySender(
		context.Background(),
		&fakeDesktopMediaGateway{
			openResp: acceptedDesktopMediaOpenResponse(),
			stream:   stream,
		},
		testDesktopMediaGatewaySenderConfig(),
		nil,
	)
	if err != nil {
		t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
	}

	reason := " gateway\nclosed\t" + strings.Repeat("x", remoteaccess.DesktopMediaMaxCloseReason)
	stream.recv <- &proto.DesktopMediaServerMessage{
		Message: &proto.DesktopMediaServerMessage_Close{
			Close: validDesktopMediaProtoClose(reason),
		},
	}

	select {
	case err := <-sender.RecvErr():
		if !errors.Is(err, errDesktopMediaStreamClosed) {
			t.Fatalf("recv error = %v, want %v", err, errDesktopMediaStreamClosed)
		}
		if strings.ContainsAny(err.Error(), "\n\t") {
			t.Fatalf("recv close reason was not normalized: %q", err.Error())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for inbound close error")
	}
}

func TestDesktopMediaGatewaySenderRejectsInboundCloseBindingMismatches(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*proto.DesktopMediaStreamClose)
	}{
		{
			name: "media ingest mismatch",
			mutate: func(closeMsg *proto.DesktopMediaStreamClose) {
				closeMsg.MediaIngestId = "other-ingest"
			},
		},
		{
			name: "agent mismatch",
			mutate: func(closeMsg *proto.DesktopMediaStreamClose) {
				closeMsg.AgentId = "other-agent"
			},
		},
		{
			name: "gateway mismatch",
			mutate: func(closeMsg *proto.DesktopMediaStreamClose) {
				closeMsg.GatewayId = "other-gateway"
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			stream := newFakeDesktopMediaStream()
			sender, err := newDesktopMediaGatewaySender(
				context.Background(),
				&fakeDesktopMediaGateway{
					openResp: acceptedDesktopMediaOpenResponse(),
					stream:   stream,
				},
				testDesktopMediaGatewaySenderConfig(),
				nil,
			)
			if err != nil {
				t.Fatalf("newDesktopMediaGatewaySender returned error: %v", err)
			}

			closeMsg := validDesktopMediaProtoClose("gateway closed")
			tc.mutate(closeMsg)
			stream.recv <- &proto.DesktopMediaServerMessage{
				Message: &proto.DesktopMediaServerMessage_Close{Close: closeMsg},
			}

			select {
			case err := <-sender.RecvErr():
				if !errors.Is(err, remoteaccess.ErrInvalidDesktopMediaFrame) {
					t.Fatalf("recv error = %v, want %v", err, remoteaccess.ErrInvalidDesktopMediaFrame)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("timed out waiting for invalid close error")
			}
		})
	}
}

func acceptedDesktopMediaOpenResponse() *proto.OpenDesktopMediaSessionResponse {
	return &proto.OpenDesktopMediaSessionResponse{
		Accepted:       true,
		MediaIngestId:  testDesktopMediaIngestID,
		MediaSessionId: testDesktopMediaID,
		MaxChunkBytes:  remoteaccess.DesktopMediaDefaultMaxChunkBytes,
	}
}

func testDesktopMediaGatewaySenderConfig() desktopMediaGatewaySenderConfig {
	return desktopMediaGatewaySenderConfig{
		DesktopSessionID: testDesktopMediaSessionID,
		MediaSessionID:   testDesktopMediaID,
		AgentID:          testDesktopMediaAgentID,
		GatewayID:        testDesktopMediaGatewayID,
		TargetID:         testDesktopMediaTargetID,
		RouteID:          testDesktopMediaRouteID,
		LeaseToken:       testDesktopMediaLease,
	}
}

func validDesktopMediaProtoAck() *proto.DesktopMediaAck {
	return &proto.DesktopMediaAck{
		DesktopSessionId:     testDesktopMediaSessionID,
		MediaSessionId:       testDesktopMediaID,
		MediaIngestId:        testDesktopMediaIngestID,
		GatewayId:            testDesktopMediaGatewayID,
		LastAcceptedSequence: 9,
		CreditBytes:          1024,
	}
}

func validDesktopMediaProtoClose(reason string) *proto.DesktopMediaStreamClose {
	return &proto.DesktopMediaStreamClose{
		DesktopSessionId: testDesktopMediaSessionID,
		MediaSessionId:   testDesktopMediaID,
		MediaIngestId:    testDesktopMediaIngestID,
		AgentId:          testDesktopMediaAgentID,
		GatewayId:        testDesktopMediaGatewayID,
		Reason:           reason,
	}
}

type fakeDesktopMediaGateway struct {
	openReq    *proto.OpenDesktopMediaSessionRequest
	openResp   *proto.OpenDesktopMediaSessionResponse
	stream     *fakeDesktopMediaStream
	streamErr  error
	closeErr   error
	closeReq   *proto.CloseDesktopMediaSessionRequest
	closeCount int
}

func (g *fakeDesktopMediaGateway) OpenDesktopMediaSession(
	_ context.Context,
	req *proto.OpenDesktopMediaSessionRequest,
) (*proto.OpenDesktopMediaSessionResponse, error) {
	g.openReq = req
	return g.openResp, nil
}

func (g *fakeDesktopMediaGateway) StreamDesktopMedia(context.Context) (desktopMediaStream, error) {
	if g.streamErr != nil {
		return nil, g.streamErr
	}
	if g.stream == nil {
		return nil, nil
	}

	return g.stream, nil
}

func (g *fakeDesktopMediaGateway) CloseDesktopMediaSession(
	_ context.Context,
	req *proto.CloseDesktopMediaSessionRequest,
) (*proto.CloseDesktopMediaSessionResponse, error) {
	g.closeReq = req
	g.closeCount++
	if g.closeErr != nil {
		return nil, g.closeErr
	}

	return &proto.CloseDesktopMediaSessionResponse{Closed: true}, nil
}

type fakeDesktopMediaStream struct {
	sent           []*proto.DesktopMediaClientMessage
	recv           chan *proto.DesktopMediaServerMessage
	closeSendCount int
}

func newFakeDesktopMediaStream() *fakeDesktopMediaStream {
	return &fakeDesktopMediaStream{recv: make(chan *proto.DesktopMediaServerMessage, 1)}
}

func (s *fakeDesktopMediaStream) Send(msg *proto.DesktopMediaClientMessage) error {
	s.sent = append(s.sent, cloneDesktopMediaClientMessageForTest(msg))
	return nil
}

func cloneDesktopMediaClientMessageForTest(msg *proto.DesktopMediaClientMessage) *proto.DesktopMediaClientMessage {
	if msg == nil {
		return nil
	}

	return goproto.Clone(msg).(*proto.DesktopMediaClientMessage)
}

func (s *fakeDesktopMediaStream) Recv() (*proto.DesktopMediaServerMessage, error) {
	msg, ok := <-s.recv
	if !ok {
		return nil, io.EOF
	}
	return msg, nil
}

func (s *fakeDesktopMediaStream) CloseSend() error {
	s.closeSendCount++
	close(s.recv)
	return nil
}
