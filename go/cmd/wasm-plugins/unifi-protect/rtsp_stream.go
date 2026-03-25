package main

import (
	"errors"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

var errProtectRTSPStreamIdle = errors.New("rtsp stream idle")

type protectRTSPReader interface {
	Read([]byte, time.Duration) (int, error)
	Close() error
}

type protectRTSPSession struct {
	reader   protectRTSPReader
	teardown func() error
}

var (
	newProtectRTSPSession    = openProtectRTSPSession
	openProtectMediaSessionF = openProtectMediaSession
	writeProtectMediaF       = writeProtectMedia
	heartbeatProtectMediaF   = heartbeatProtectMedia
	closeProtectMediaF       = closeProtectMedia
	protectNow               = time.Now
)

func streamProtectRTSP(cfg StreamConfig, timeout time.Duration, sourceURL string) error {
	session, err := newProtectRTSPSession(cfg, timeout, sourceURL)
	if err != nil {
		return err
	}
	closeReason := "rtsp stream closed"
	defer func() {
		if session.teardown != nil {
			_ = session.teardown()
		}
		if session.reader != nil {
			_ = session.reader.Close()
		}
	}()

	stream, err := openProtectMediaSessionF(protectMediaOpenRequest{
		TrackID:       "video",
		Codec:         "h264",
		PayloadFormat: "annexb",
	})
	if err != nil {
		return err
	}
	defer func() { _ = closeProtectMediaF(stream, closeReason) }()

	depacketizer := &sdk.RTSPH264Depacketizer{}
	buf := make([]byte, 64*1024)
	idleReads := 0
	lastHeartbeat := protectNow()
	var sequence uint64

	for {
		n, err := session.reader.Read(buf, 1500*time.Millisecond)
		if err != nil {
			idleReads++
			if idleReads >= 5 {
				closeReason = "rtsp stream idle"
				return errProtectRTSPStreamIdle
			}
			if protectNow().Sub(lastHeartbeat) >= time.Second {
				if err := heartbeatProtectMediaF(stream, protectMediaHeartbeat{
					Sequence:      sequence,
					TimestampUnix: protectNow().Unix(),
				}); err != nil {
					closeReason = "rtsp heartbeat failed"
					return err
				}
				lastHeartbeat = protectNow()
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
		if err := writeProtectMediaF(stream, protectMediaChunkMetadata{
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

		if protectNow().Sub(lastHeartbeat) >= time.Second {
			if err := heartbeatProtectMediaF(stream, protectMediaHeartbeat{
				Sequence:      sequence,
				TimestampUnix: protectNow().Unix(),
			}); err != nil {
				closeReason = "rtsp heartbeat failed"
				return err
			}
			lastHeartbeat = protectNow()
		}
	}
}

func openProtectRTSPSession(cfg StreamConfig, timeout time.Duration, sourceURL string) (*protectRTSPSession, error) {
	endpoint, err := sdk.ParseRTSPEndpoint(sourceURL, cfg.Username, cfg.Password)
	if err != nil {
		return nil, err
	}

	conn, err := sdk.DialRTSPTransport(endpoint, timeout, cfg.InsecureSkipVerify)
	if err != nil {
		return nil, err
	}

	client := sdk.NewRTSPClient(conn, timeout, endpoint)
	if _, err := client.DoRequest("OPTIONS", endpoint.RequestURI, nil); err != nil {
		_ = conn.Close()
		return nil, err
	}

	describe, err := client.DoRequest("DESCRIBE", endpoint.RequestURI, map[string]string{
		"Accept": "application/sdp",
	})
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	track, err := sdk.ParseH264TrackFromSDP(endpoint, describe.Body)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	setup, err := client.DoRequest("SETUP", track.ControlURL, map[string]string{
		"Transport": "RTP/AVP/TCP;unicast;interleaved=0-1",
	})
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	session := sdk.ParseSessionHeader(setup.Headers["session"])
	if session == "" {
		_ = conn.Close()
		return nil, sdk.ErrRTSPNoSession
	}
	client.Session = session

	if _, err := client.DoRequest("PLAY", endpoint.RequestURI, nil); err != nil {
		_ = conn.Close()
		return nil, err
	}

	return &protectRTSPSession{
		reader: conn,
		teardown: func() error {
			return client.Teardown()
		},
	}, nil
}
