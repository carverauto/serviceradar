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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
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
			!ack.Pause {
			t.Fatalf("ack = %#v", ack)
		}
	case <-sender.RecvErr():
		t.Fatal("sender returned receive error before ack")
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for desktop media ack")
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
	if len(stream.sent) != 0 {
		t.Fatalf("invalid frame was forwarded: %#v", stream.sent)
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
	})
	if !errors.Is(err, errDesktopMediaStreamClosed) {
		t.Fatalf("post-close send error = %v, want %v", err, errDesktopMediaStreamClosed)
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

type fakeDesktopMediaGateway struct {
	openReq    *proto.OpenDesktopMediaSessionRequest
	openResp   *proto.OpenDesktopMediaSessionResponse
	stream     *fakeDesktopMediaStream
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
	return g.stream, nil
}

func (g *fakeDesktopMediaGateway) CloseDesktopMediaSession(
	_ context.Context,
	req *proto.CloseDesktopMediaSessionRequest,
) (*proto.CloseDesktopMediaSessionResponse, error) {
	g.closeReq = req
	g.closeCount++
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
	s.sent = append(s.sent, msg)
	return nil
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
