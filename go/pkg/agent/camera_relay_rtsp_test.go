package agent

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	codech264 "github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
)

// A fresh relay joins a camera mid-GOP: non-IDR frames arrive before the first
// keyframe. Its first chunk must still be a keyframe that decodes on its own,
// and every chunk's PTS must lie on one timeline that follows the RTP clock, so
// the recorder never sees time run backwards.
func TestRTSPCameraRelayStartsAtKeyframeOnOneTimeline(t *testing.T) {
	t.Parallel()

	// Invented NAL units; the receiver routes on NAL type, not SPS content.
	sps := []byte{0x67, 0x42, 0xc0, 0x1e, 0xda, 0x02}
	pps := []byte{0x68, 0xce, 0x3c, 0x80}
	idr := []byte{0x65, 0x88, 0x84, 0x21, 0xa0}
	nonIDR := func(n byte) [][]byte { return [][]byte{{0x41, 0x9a, 0x02, n}} }
	wantKeyframe, err := codech264.AnnexB{sps, pps, idr}.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name     string
		keyframe [][]byte
	}{
		// Parameter sets already in-band must not be repeated from the SDP.
		{name: "in-band parameter sets", keyframe: [][]byte{sps, pps, idr}},
		// A camera that announces them only in the SDP gets them prepended.
		{name: "parameter sets only in SDP", keyframe: [][]byte{idr}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			units := [][][]byte{nonIDR(1), nonIDR(2), tc.keyframe, nonIDR(3), nonIDR(4), nonIDR(5)}
			const firstKeyframe = 2
			chunks := relaySyntheticH264(t, sps, pps, units, len(units)-firstKeyframe)

			if !chunks[0].Keyframe || !bytes.Equal(chunks[0].Payload, wantKeyframe) {
				t.Fatalf("first chunk: keyframe=%t payload=%x, want keyframe %x", chunks[0].Keyframe, chunks[0].Payload, wantKeyframe)
			}
			for i, chunk := range chunks {
				if got, want := chunk.PTS-chunks[0].PTS, int64(i*syntheticFrameTicks); got != want || chunk.DTS != chunk.PTS {
					t.Fatalf("chunk %d: pts offset %d dts %d, want offset %d on the RTP timeline", i, got, chunk.DTS, want)
				}
			}
		})
	}
}

// syntheticFrameTicks is one frame at 30 fps on the 90 kHz H264 RTP clock.
const syntheticFrameTicks = 3_000

// relaySyntheticH264 serves units, one access unit per syntheticFrameTicks of
// RTP time, from a loopback RTSP camera that announces sps/pps in its SDP, and
// returns the first n chunks the production receiver emits.
func relaySyntheticH264(t *testing.T, sps, pps []byte, units [][][]byte, n int) []*cameraRelayChunk {
	t.Helper()

	server, handler, url := startSyntheticCameraRTSP(t, false)
	media := &description.Media{
		Type:    description.MediaTypeVideo,
		Formats: []format.Format{&format.H264{PayloadTyp: 96, PacketizationMode: 1, SPS: sps, PPS: pps}},
	}
	stream := &gortsplib.ServerStream{Server: server, Desc: &description.Session{Medias: []*description.Media{media}}}
	if err := stream.Initialize(); err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	handler.mu.Lock()
	handler.stream = stream
	handler.mu.Unlock()

	receiver, err := newRTSPCameraRelayStream(cameraRelaySessionSpec{SourceURL: url, RTSPTransport: "tcp"}, createTestLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = receiver.Close() }()

	encoder := &rtph264.Encoder{PayloadType: 96, PacketizationMode: 1}
	if err := encoder.Init(); err != nil {
		t.Fatal(err)
	}
	for i, unit := range units {
		packets, err := encoder.Encode(unit)
		if err != nil {
			t.Fatal(err)
		}
		for _, packet := range packets {
			packet.Timestamp = 90_000 + uint32(i)*syntheticFrameTicks
			if err := stream.WritePacketRTP(media, packet); err != nil {
				t.Fatal(err)
			}
		}
	}

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	chunks := make([]*cameraRelayChunk, 0, n)
	for len(chunks) < n {
		chunk, err := receiver.Recv(ctx)
		if err != nil {
			t.Fatalf("chunk %d: %v", len(chunks), err)
		}
		chunks = append(chunks, chunk)
	}
	return chunks
}
