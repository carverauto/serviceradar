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
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	codech264 "github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
	"github.com/pion/rtp"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/tlsclient"
)

const defaultCameraRelayChunkBuffer = 64

const (
	cameraRelayRTSPTransportTCP = "tcp"
	cameraRelayRTSPTransportUDP = "udp"
)

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

func defaultCameraRelaySource(spec cameraRelaySessionSpec, log logger.Logger) (cameraRelayChunkStream, error) {
	sourceURL := strings.TrimSpace(spec.SourceURL)
	if sourceURL == "" {
		return nil, errCameraRelaySourceURLRequired
	}

	switch {
	case strings.HasPrefix(strings.ToLower(sourceURL), "rtsp://"),
		strings.HasPrefix(strings.ToLower(sourceURL), "rtsps://"):
		return newRTSPCameraRelayStream(spec, log)

	default:
		return nil, fmt.Errorf("%w %q", errUnsupportedCameraRelaySource, sourceURL)
	}
}

func newRTSPCameraRelayStream(spec cameraRelaySessionSpec, log logger.Logger) (cameraRelayChunkStream, error) {
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
	gate := newCameraRelayKeyframeGate(h264Format.SPS, h264Format.PPS)

	// A relay has one clock: every chunk's PTS is client.PacketPTS, the track's
	// gortsplib timeline. That timeline starts at the first packet carrying an
	// IDR, SPS or PPS; packets before it have no PTS and are dropped rather than
	// stamped from a second, earlier zero, which is what made a fresh relay's
	// PTS run backwards at its first keyframe. Decoded access units are then
	// held back until the first IDR whose parameter sets are known. So a relay's
	// first chunk is a keyframe that decodes on its own, and PTS never decreases
	// across its chunks. PTS is that of the packet completing the access unit;
	// for a camera that never sets the RTP marker that packet belongs to the
	// next unit, a constant one-frame offset on the same timeline.
	client.OnPacketRTP(media, h264Format, func(pkt *rtp.Packet) {
		pts, ok := client.PacketPTS(media, pkt)
		if !ok {
			gate.droppedPackets.Add(1)
			return
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

		acquiring := !gate.acquired.Load()
		accessUnit, ok = gate.admit(accessUnit)
		if !ok {
			return
		}
		if acquiring {
			log.Debug().
				Str("relay_session_id", spec.RelaySessionID).
				Uint64("discarded_packets", gate.droppedPackets.Load()).
				Uint64("discarded_access_units", gate.droppedUnits.Load()).
				Msg("Camera relay RTSP receiver started at the first keyframe")
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

	// The client read timeout only covers a silent source. A source that keeps
	// sending without ever producing a usable keyframe would otherwise leave the
	// relay emitting nothing, so acquisition has its own deadline.
	keyframeDeadline := time.AfterFunc(cameraRelayFirstKeyframeTimeout, func() {
		if gate.acquired.Load() {
			return
		}
		stream.fail(fmt.Errorf("%w within %s (%d packets before the stream clock started, %d access units before a usable IDR)",
			errCameraRelayNoKeyframe, cameraRelayFirstKeyframeTimeout,
			gate.droppedPackets.Load(), gate.droppedUnits.Load()))
	})

	go func() {
		waitErr := client.Wait()
		keyframeDeadline.Stop()
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
		client.TLSConfig = tlsclient.Config(tlsclient.Policy{
			InsecureSkipVerify: true,
			OptIn:              "camera_relay.insecure_skip_verify",
			Target:             u.Host,
		})
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

	// Record the cause before closing: Close ends client.Wait, whose generic
	// termination error would otherwise race this one into the terminal slot.
	s.finish(err)
	_ = s.Close()
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
	case "", cameraRelayRTSPTransportTCP:
		return gortsplib.ProtocolTCP, nil
	case cameraRelayRTSPTransportUDP:
		return gortsplib.ProtocolUDP, nil
	default:
		return 0, fmt.Errorf("%w %q", errUnsupportedCameraRelayTransport, value)
	}
}

// cameraRelayFirstKeyframeTimeout bounds how long a fresh relay waits for its
// first decodable IDR. It is several typical camera GOPs; the recorder applies
// its own, stricter keyframe limits downstream.
const cameraRelayFirstKeyframeTimeout = 30 * time.Second

var errCameraRelayNoKeyframe = errors.New("rtsp stream produced no decodable h264 keyframe")

// cameraRelayKeyframeGate holds a relay's output back until its first IDR whose
// SPS and PPS are known, from the SDP or in-band. admit runs only on the RTP
// callback goroutine; the counters and flag are atomic because the acquisition
// deadline reads them from a timer goroutine.
type cameraRelayKeyframeGate struct {
	sps, pps       []byte
	acquired       atomic.Bool
	droppedPackets atomic.Uint64
	droppedUnits   atomic.Uint64
}

func newCameraRelayKeyframeGate(sps, pps []byte) *cameraRelayKeyframeGate {
	return &cameraRelayKeyframeGate{sps: bytes.Clone(sps), pps: bytes.Clone(pps)}
}

// admit returns the access unit to emit, or false while the relay is still
// waiting. The first admitted unit carries SPS and PPS ahead of its slices.
func (g *cameraRelayKeyframeGate) admit(au [][]byte) ([][]byte, bool) {
	if g.acquired.Load() {
		return au, true
	}

	var idr, inBandSPS, inBandPPS bool
	for _, nalu := range au {
		// Switch on the raw type byte: only three of the 32 NAL types matter here.
		switch nalu[0] & 0x1F {
		case byte(codech264.NALUTypeSPS):
			g.sps, inBandSPS = bytes.Clone(nalu), true
		case byte(codech264.NALUTypePPS):
			g.pps, inBandPPS = bytes.Clone(nalu), true
		case byte(codech264.NALUTypeIDR):
			idr = true
		}
	}
	if !idr || len(g.sps) == 0 || len(g.pps) == 0 {
		g.droppedUnits.Add(1)
		return nil, false
	}

	g.acquired.Store(true)
	if inBandSPS && inBandPPS {
		return au, true
	}
	return withCameraRelayParameterSets(au, g.sps, g.pps), true
}

// withCameraRelayParameterSets places sps and pps after any leading access
// unit delimiter. A lone in-band set is dropped from its old position (admit
// already recorded it), so neither set appears twice.
func withCameraRelayParameterSets(au [][]byte, sps, pps []byte) [][]byte {
	out := make([][]byte, 0, len(au)+2)
	rest := au
	if len(rest) > 0 && codech264.NALUType(rest[0][0]&0x1F) == codech264.NALUTypeAccessUnitDelimiter {
		out = append(out, rest[0])
		rest = rest[1:]
	}
	out = append(out, sps, pps)
	for _, nalu := range rest {
		if typ := codech264.NALUType(nalu[0] & 0x1F); typ != codech264.NALUTypeSPS && typ != codech264.NALUTypePPS {
			out = append(out, nalu)
		}
	}
	return out
}
