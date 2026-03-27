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
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	codech264 "github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
	"github.com/pion/rtp"
)

const defaultCameraRelayChunkBuffer = 64

var (
	errCameraRelaySourceURLRequired    = errors.New("source_url is required")
	errUnsupportedCameraRelaySource    = errors.New("unsupported camera relay source")
	errCameraRelayNoH264MediaFormat    = errors.New("rtsp stream does not expose an H264 media format")
	errUnsupportedCameraRelayTransport = errors.New("unsupported rtsp_transport")
)

type rtspCameraRelayStream struct {
	client     *gortsplib.Client
	chunks     chan *cameraRelayChunk
	terminal   chan error
	done       chan struct{}
	closeOnce  sync.Once
	terminalMu sync.Mutex
	closed     bool
}

type cameraRelayTimestampDecoder struct {
	mu        sync.Mutex
	clockRate int64
	init      bool
	prev      uint32
	pts       int64
}

func defaultCameraRelaySource(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
	sourceURL := strings.TrimSpace(spec.SourceURL)
	if sourceURL == "" {
		return nil, errCameraRelaySourceURLRequired
	}

	switch {
	case strings.HasPrefix(strings.ToLower(sourceURL), "rtsp://"),
		strings.HasPrefix(strings.ToLower(sourceURL), "rtsps://"):
		return newRTSPCameraRelayStream(spec)

	default:
		return nil, fmt.Errorf("%w %q", errUnsupportedCameraRelaySource, sourceURL)
	}
}

func newRTSPCameraRelayStream(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
	sourceURL := strings.TrimSpace(spec.SourceURL)
	u, err := base.ParseURL(sourceURL)
	if err != nil {
		return nil, fmt.Errorf("parse rtsp source_url: %w", err)
	}

	transport, err := parseCameraRelayRTSPTransport(spec.RTSPTransport)
	if err != nil {
		return nil, err
	}

	client := newCameraRelayRTSPClient(u, transport, spec.InsecureSkipVerify)
	if err := client.Start(); err != nil {
		return nil, fmt.Errorf("start rtsp client: %w", err)
	}

	desc, _, err := client.Describe(u)
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("describe rtsp stream: %w", err)
	}

	var h264Format *format.H264
	media := desc.FindFormat(&h264Format)
	if media == nil {
		client.Close()
		return nil, errCameraRelayNoH264MediaFormat
	}

	decoder, err := h264Format.CreateDecoder()
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("create h264 decoder: %w", err)
	}

	if _, err := client.Setup(desc.BaseURL, media, 0, 0); err != nil {
		client.Close()
		return nil, fmt.Errorf("setup rtsp media: %w", err)
	}

	stream := &rtspCameraRelayStream{
		client:   client,
		chunks:   make(chan *cameraRelayChunk, defaultCameraRelayChunkBuffer),
		terminal: make(chan error, 1),
		done:     make(chan struct{}),
	}

	var sequence uint64
	timestampDecoder := newCameraRelayTimestampDecoder(int64(h264Format.ClockRate()))

	client.OnPacketRTP(media, h264Format, func(pkt *rtp.Packet) {
		pts, ok := client.PacketPTS(media, pkt)
		if !ok {
			pts = timestampDecoder.Decode(pkt.Timestamp)
		}

		accessUnit, decodeErr := decoder.Decode(pkt)
		if decodeErr != nil {
			if errors.Is(decodeErr, rtph264.ErrNonStartingPacketAndNoPrevious) ||
				errors.Is(decodeErr, rtph264.ErrMorePacketsNeeded) {
				return
			}

			stream.fail(fmt.Errorf("decode h264 access unit: %w", decodeErr))
			return
		}

		payload, marshalErr := codech264.AnnexB(accessUnit).Marshal()
		if marshalErr != nil {
			stream.fail(fmt.Errorf("marshal h264 annexb: %w", marshalErr))
			return
		}

		sequence++
		chunk := &cameraRelayChunk{
			TrackID:       "video",
			Payload:       payload,
			Sequence:      sequence,
			PTS:           pts,
			DTS:           pts,
			Keyframe:      codech264.IsRandomAccess(accessUnit),
			Codec:         "h264",
			PayloadFormat: "annexb",
		}

		select {
		case stream.chunks <- chunk:
		case <-stream.done:
		}
	})

	if _, err := client.Play(nil); err != nil {
		_ = stream.Close()
		return nil, fmt.Errorf("play rtsp stream: %w", err)
	}

	go func() {
		waitErr := client.Wait()
		if waitErr == nil {
			waitErr = io.EOF
		}
		stream.finish(waitErr)
	}()

	return stream, nil
}

func newCameraRelayRTSPClient(u *base.URL, transport gortsplib.Protocol, insecureSkipVerify bool) *gortsplib.Client {
	client := &gortsplib.Client{
		Scheme:   u.Scheme,
		Host:     u.Host,
		Protocol: &transport,
	}
	if strings.EqualFold(u.Scheme, "rtsps") && insecureSkipVerify {
		client.TLSConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	}
	return client
}

func (s *rtspCameraRelayStream) Recv(ctx context.Context) (*cameraRelayChunk, error) {
	if s == nil {
		return nil, io.EOF
	}

	select {
	case chunk := <-s.chunks:
		if chunk == nil {
			return nil, io.EOF
		}
		return chunk, nil
	default:
	}

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case chunk := <-s.chunks:
		if chunk == nil {
			return nil, io.EOF
		}
		return chunk, nil
	case err := <-s.terminal:
		return nil, err
	}
}

func (s *rtspCameraRelayStream) Close() error {
	if s == nil {
		return nil
	}

	s.closeOnce.Do(func() {
		close(s.done)
		if s.client != nil {
			s.client.Close()
		}
	})

	return nil
}

func (s *rtspCameraRelayStream) fail(err error) {
	if err == nil {
		return
	}

	_ = s.Close()
	s.finish(err)
}

func (s *rtspCameraRelayStream) finish(err error) {
	if s == nil || err == nil {
		return
	}

	s.terminalMu.Lock()
	defer s.terminalMu.Unlock()

	if s.closed {
		return
	}
	s.closed = true

	select {
	case s.terminal <- err:
	default:
	}
}

func parseCameraRelayRTSPTransport(value string) (gortsplib.Protocol, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "tcp":
		return gortsplib.ProtocolTCP, nil
	case "udp":
		return gortsplib.ProtocolUDP, nil
	default:
		return 0, fmt.Errorf("%w %q", errUnsupportedCameraRelayTransport, value)
	}
}

func newCameraRelayTimestampDecoder(clockRate int64) *cameraRelayTimestampDecoder {
	return &cameraRelayTimestampDecoder{clockRate: clockRate}
}

func (d *cameraRelayTimestampDecoder) Decode(timestamp uint32) int64 {
	if d == nil || d.clockRate <= 0 {
		return 0
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	if !d.init {
		d.init = true
		d.prev = timestamp
		d.pts = 0
		return 0
	}

	delta := int64(int32(timestamp - d.prev))
	d.prev = timestamp
	d.pts += delta * int64(time.Second) / d.clockRate
	if d.pts < 0 {
		d.pts = 0
	}

	return d.pts
}
