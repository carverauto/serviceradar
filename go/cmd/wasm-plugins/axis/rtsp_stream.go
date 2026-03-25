package main

import (
	"errors"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

var errRTSPStreamIdle = errors.New("rtsp stream idle")

func streamAxisRTSP(cfg StreamConfig, timeout time.Duration) error {
	sourceURL := buildAxisStreamSourceURL(cfg)
	endpoint, err := sdk.ParseRTSPEndpoint(sourceURL, cfg.Username, cfg.Password)
	if err != nil {
		return err
	}

	conn, err := sdk.TCPDial(endpoint.Host, endpoint.Port, timeout)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	client := sdk.NewRTSPClient(conn, timeout, endpoint)
	closeReason := "rtsp stream closed"
	defer func() {
		_ = client.Teardown()
	}()

	if _, err := client.DoRequest("OPTIONS", endpoint.RequestURI, nil); err != nil {
		return err
	}

	describe, err := client.DoRequest("DESCRIBE", endpoint.RequestURI, map[string]string{
		"Accept": "application/sdp",
	})
	if err != nil {
		return err
	}

	track, err := sdk.ParseH264TrackFromSDP(endpoint, describe.Body)
	if err != nil {
		return err
	}

	setup, err := client.DoRequest("SETUP", track.ControlURL, map[string]string{
		"Transport": "RTP/AVP/TCP;unicast;interleaved=0-1",
	})
	if err != nil {
		return err
	}

	session := sdk.ParseSessionHeader(setup.Headers["session"])
	if session == "" {
		return sdk.ErrRTSPNoSession
	}
	client.Session = session

	if _, err := client.DoRequest("PLAY", endpoint.RequestURI, nil); err != nil {
		return err
	}

	stream, err := openAxisMediaSession(axisMediaOpenRequest{
		TrackID:       "video",
		Codec:         "h264",
		PayloadFormat: "annexb",
	})
	if err != nil {
		return err
	}
	defer func() { _ = closeAxisMedia(stream, closeReason) }()

	depacketizer := &sdk.RTSPH264Depacketizer{}
	buf := make([]byte, 64*1024)
	idleReads := 0
	lastHeartbeat := time.Now()
	var sequence uint64

	for {
		n, err := conn.Read(buf, 1500*time.Millisecond)
		if err != nil {
			idleReads++
			if idleReads >= 5 {
				closeReason = "rtsp stream idle"
				return errRTSPStreamIdle
			}
			if time.Since(lastHeartbeat) >= time.Second {
				if err := heartbeatAxisMedia(stream, axisMediaHeartbeat{
					Sequence:      sequence,
					TimestampUnix: time.Now().Unix(),
				}); err != nil {
					closeReason = "rtsp heartbeat failed"
					return err
				}
				lastHeartbeat = time.Now()
			}
			continue
		}
		idleReads = 0

		frame, err := sdk.ParseInterleavedFrame(buf[:n])
		if err != nil {
			continue
		}
		if frame.Channel != 0 {
			continue
		}

		packet, marker, timestamp, err := sdk.ParseRTPPacket(frame.Payload)
		if err != nil {
			continue
		}

		accessUnit, keyframe, complete, err := depacketizer.Push(packet, marker, timestamp)
		if err != nil || !complete || len(accessUnit) == 0 {
			continue
		}

		sequence++
		if err := writeAxisMedia(stream, axisMediaChunkMetadata{
			TrackID:       "video",
			Sequence:      sequence,
			PTS:           int64(timestamp),
			DTS:           int64(timestamp),
			Keyframe:      keyframe,
			Codec:         "h264",
			PayloadFormat: "annexb",
		}, accessUnit); err != nil {
			closeReason = "rtsp media write failed"
			return err
		}

		if time.Since(lastHeartbeat) >= time.Second {
			if err := heartbeatAxisMedia(stream, axisMediaHeartbeat{
				Sequence:      sequence,
				TimestampUnix: time.Now().Unix(),
			}); err != nil {
				closeReason = "rtsp heartbeat failed"
				return err
			}
			lastHeartbeat = time.Now()
		}
	}
}
