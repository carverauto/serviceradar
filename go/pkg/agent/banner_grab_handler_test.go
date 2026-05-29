/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package agent

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"google.golang.org/protobuf/proto"
)

const testHostIP = "192.0.2.10"

func TestHandleBannerObservationsMatchesAndEnqueuesFingerprintEvents(t *testing.T) {
	t.Parallel()

	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)

		frame, err := readTestNetprobeFrame(serverConn)
		if err != nil {
			t.Errorf("read netprobe frame: %v", err)
			return
		}

		batch := frame.GetBannerBatch()
		if batch == nil || len(batch.GetObservations()) != 1 {
			t.Errorf("frame payload = %T, want one banner observation", frame.GetPayload())
			return
		}

		observation := batch.GetObservations()[0]
		if observation.GetProtocol() != banner_grab.ProtocolSSH || observation.GetSource() != banner_grab.SourceSweepActive {
			t.Errorf("observation protocol/source = %q/%q, want ssh/sweep_active", observation.GetProtocol(), observation.GetSource())
		}

		err = writeTestNetprobeFrame(serverConn, &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_BannerMatchBatch{
				BannerMatchBatch: &netprobepb.BannerMatchBatch{
					Matches: []*netprobepb.BannerMatch{{
						ObservationId: observation.GetObservationId(),
						CorpusLabel:   "recog",
						OsFamily:      "linux",
						Product:       "OpenSSH",
						Version:       "9.6",
						Confidence:    0.96,
						RawPatternId:  "recog:ssh:openssh",
					}},
				},
			},
		})
		if err != nil {
			t.Errorf("write netprobe frame: %v", err)
		}
	}()

	client := agentnetprobe.NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	sidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{})
	sidecar.OnHealthy(client)

	engine := banner_grab.New(banner_grab.Config{
		Enabled:               true,
		Protocols:             []string{banner_grab.ProtocolSSH},
		Ports:                 map[string][]int{banner_grab.ProtocolSSH: {22}},
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        128,
		MaxGlobalConcurrency:  1,
		MaxCandidateQueue:     1,
		MaxConcurrencyPerHost: 1,
	})

	observations := make(chan banner_grab.BannerObservation, 1)
	observations <- banner_grab.BannerObservation{
		ObservationID: 77,
		Host:          testHostIP,
		Port:          22,
		Protocol:      banner_grab.ProtocolSSH,
		Source:        banner_grab.SourceSweepActive,
		BannerBytes:   []byte("SSH-2.0-OpenSSH_9.6"),
		ObservedAt:    time.Unix(1_700_000_000, 0),
	}
	close(observations)

	server := &Server{
		logger:          logger.NewTestLogger(),
		netprobeSidecar: sidecar,
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	err := server.handleBannerObservations(ctx, models.BannerGrab{
		MatchBatchSize:     1,
		MatchBatchMaxBytes: 4096,
	}, engine, observations)
	if err != nil {
		t.Fatalf("handleBannerObservations() error = %v", err)
	}

	events := sidecar.DrainEvents(10)
	if len(events) != 1 {
		t.Fatalf("DrainEvents() len = %d, want 1", len(events))
	}

	event := events[0]
	if event.GetIp() != testHostIP || event.GetProfileId() != banner_grab.SourceSweepActive {
		t.Fatalf("event ip/profile = %q/%q, want 192.0.2.10/sweep_active", event.GetIp(), event.GetProfileId())
	}

	fingerprint := event.GetLicenseClean()
	if fingerprint == nil || fingerprint.GetRecogSsh().GetProduct() != "OpenSSH" || !fingerprint.GetSshObserved() {
		t.Fatalf("license-clean fingerprint = %#v, want SSH OpenSSH evidence", fingerprint)
	}

	stats := engine.Stats()
	if stats.MatchBatchesTotal != 1 || stats.MatchesTotal != 1 {
		t.Fatalf("match stats batches=%d matches=%d, want 1/1", stats.MatchBatchesTotal, stats.MatchesTotal)
	}

	_ = client.Close()
	<-serverDone
}

func TestBannerMatchToFingerprintEventCarriesSMTPAndNTPRecogEvidence(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name     string
		protocol string
		assert   func(t *testing.T, fingerprint *netprobepb.LicenseCleanFingerprint)
	}{
		{
			name:     "smtp",
			protocol: banner_grab.ProtocolSMTP,
			assert: func(t *testing.T, fingerprint *netprobepb.LicenseCleanFingerprint) {
				t.Helper()
				if fingerprint.GetRecogSmtp().GetProduct() != "Postfix" {
					t.Fatalf("RecogSmtp = %#v, want Postfix", fingerprint.GetRecogSmtp())
				}
			},
		},
		{
			name:     "ntp",
			protocol: banner_grab.ProtocolNTP,
			assert: func(t *testing.T, fingerprint *netprobepb.LicenseCleanFingerprint) {
				t.Helper()
				if fingerprint.GetRecogNtp().GetProduct() != "Postfix" || !fingerprint.GetNtpObserved() {
					t.Fatalf("NTP fingerprint = %#v, want RecogNtp and observed flag", fingerprint)
				}
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			event := bannerMatchToFingerprintEvent(
				banner_grab.BannerObservation{
					ObservationID: 42,
					Host:          testHostIP,
					Protocol:      tc.protocol,
					Source:        banner_grab.SourceSweepActive,
					ObservedAt:    time.Unix(1_700_000_000, 0),
				},
				&netprobepb.BannerMatch{
					ObservationId: 42,
					CorpusLabel:   "recog",
					OsFamily:      "linux",
					Product:       "Postfix",
					Version:       "3.8",
					Confidence:    0.9,
				},
			)

			fingerprint := event.GetLicenseClean()
			if fingerprint == nil {
				t.Fatal("LicenseClean = nil")
			}

			tc.assert(t, fingerprint)
		})
	}
}

func readTestNetprobeFrame(r io.Reader) (*netprobepb.NetprobeFrame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}

	body := make([]byte, binary.BigEndian.Uint32(lenBuf[:]))
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}

	var frame netprobepb.NetprobeFrame
	if err := proto.Unmarshal(body, &frame); err != nil {
		return nil, err
	}

	return &frame, nil
}

func writeTestNetprobeFrame(w io.Writer, frame *netprobepb.NetprobeFrame) error {
	body, err := proto.Marshal(frame)
	if err != nil {
		return err
	}

	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(body)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	_, err = w.Write(body)

	return err
}
