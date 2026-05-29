/*
 * Copyright 2026 Carver Automation Corporation.
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
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const bannerMatchFlushInterval = 500 * time.Millisecond

func (s *Server) handleBannerObservations(
	ctx context.Context,
	config models.BannerGrab,
	engine *banner_grab.Engine,
	observations <-chan banner_grab.BannerObservation,
) error {
	batcher := banner_grab.NewBatcher(config.MatchBatchSize, config.MatchBatchMaxBytes)
	timer := time.NewTimer(bannerMatchFlushInterval)
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	defer timer.Stop()
	var timerC <-chan time.Time

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timerC:
			if err := s.flushBannerBatch(ctx, engine, batcher.Flush()); err != nil {
				return err
			}
			timerC = nil
		case observation, ok := <-observations:
			if !ok {
				return s.flushBannerBatch(ctx, engine, batcher.Flush())
			}

			if timerC == nil {
				timer.Reset(bannerMatchFlushInterval)
				timerC = timer.C
			}
			if batch, flush := batcher.Add(observation); flush {
				if err := s.flushBannerBatch(ctx, engine, batch); err != nil {
					return err
				}
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				timerC = nil
			}
		}
	}
}

func (s *Server) flushBannerBatch(
	ctx context.Context,
	engine *banner_grab.Engine,
	observations []banner_grab.BannerObservation,
) error {
	if len(observations) == 0 {
		return nil
	}
	if s.netprobeSidecar == nil {
		s.logger.Warn().Int("observations", len(observations)).Msg("Skipping banner-grab batch because netprobe sidecar is unavailable")
		return nil
	}

	matches, err := s.netprobeSidecar.MatchBanners(ctx, bannerObservationsToProto(observations))
	if err != nil {
		return err
	}

	events := bannerMatchesToFingerprintEvents(observations, matches.GetMatches())
	for _, event := range events {
		s.netprobeSidecar.EnqueueFingerprintEvent(event)
	}
	if engine != nil {
		engine.RecordMatchBatch(bannerObservationBatchBytes(observations), len(events))
	}

	s.logger.Info().
		Int("observations", len(observations)).
		Int("matches", len(events)).
		Msg("Matched banner-grab observations")

	return nil
}

func bannerObservationBatchBytes(observations []banner_grab.BannerObservation) int {
	total := 0
	for _, observation := range observations {
		total += len(observation.Host)
		total += len(observation.Protocol)
		total += len(observation.Source)
		total += len(observation.BannerBytes)
		total += 32
	}

	return total
}

func bannerObservationsToProto(observations []banner_grab.BannerObservation) *netprobepb.BannerBatch {
	out := &netprobepb.BannerBatch{
		Observations: make([]*netprobepb.BannerObservation, 0, len(observations)),
	}

	for _, observation := range observations {
		out.Observations = append(out.Observations, &netprobepb.BannerObservation{
			ObservationId: observation.ObservationID,
			Host:          strings.TrimSpace(observation.Host),
			Port:          uint32(observation.Port),
			Protocol:      strings.ToLower(strings.TrimSpace(observation.Protocol)),
			BannerBytes:   append([]byte(nil), observation.BannerBytes...),
			ObservedAt:    observation.ObservedAt.UnixNano(),
			Source:        strings.TrimSpace(observation.Source),
		})
	}

	return out
}

func bannerMatchesToFingerprintEvents(
	observations []banner_grab.BannerObservation,
	matches []*netprobepb.BannerMatch,
) []*netprobepb.FingerprintEvent {
	byID := make(map[uint64]banner_grab.BannerObservation, len(observations))
	for _, observation := range observations {
		byID[observation.ObservationID] = observation
	}

	events := make([]*netprobepb.FingerprintEvent, 0, len(matches))
	for _, match := range matches {
		if match == nil || match.GetConfidence() <= 0 || strings.EqualFold(match.GetCorpusLabel(), "unknown") {
			continue
		}

		observation, ok := byID[match.GetObservationId()]
		if !ok {
			continue
		}

		events = append(events, bannerMatchToFingerprintEvent(observation, match))
	}

	return events
}

func bannerMatchToFingerprintEvent(
	observation banner_grab.BannerObservation,
	match *netprobepb.BannerMatch,
) *netprobepb.FingerprintEvent {
	protocol := strings.ToLower(strings.TrimSpace(observation.Protocol))
	fingerprint := &netprobepb.LicenseCleanFingerprint{
		AgreementCount: 1,
		OsMatch: &netprobepb.OsMatch{
			Name:         strings.TrimSpace(match.GetProduct()),
			VersionRange: strings.TrimSpace(match.GetVersion()),
			OsFamily:     strings.TrimSpace(match.GetOsFamily()),
			Confidence:   float32(match.GetConfidence()),
		},
	}

	recog := &netprobepb.RecogFingerprintMatch{
		Product:  strings.TrimSpace(match.GetProduct()),
		Version:  strings.TrimSpace(match.GetVersion()),
		OsFamily: strings.TrimSpace(match.GetOsFamily()),
	}

	switch protocol {
	case banner_grab.ProtocolHTTP:
		fingerprint.RecogHttp = recog
		fingerprint.HttpObserved = true
	case banner_grab.ProtocolSSH:
		fingerprint.RecogSsh = recog
		fingerprint.SshObserved = true
	case banner_grab.ProtocolSMB:
		fingerprint.RecogSmb = recog
		fingerprint.SmbObserved = true
	case banner_grab.ProtocolFTP:
		fingerprint.RecogFtp = recog
	case banner_grab.ProtocolTelnet:
		fingerprint.RecogTelnet = recog
	case banner_grab.ProtocolSMTP:
		fingerprint.RecogSmtp = recog
	case banner_grab.ProtocolRDP:
		fingerprint.RecogRdp = recog
	case banner_grab.ProtocolDNS:
		fingerprint.RecogDns = recog
		fingerprint.DnsObserved = true
	case banner_grab.ProtocolNTP:
		fingerprint.RecogNtp = recog
		fingerprint.NtpObserved = true
	}

	if strings.Contains(strings.ToLower(match.GetCorpusLabel()), "satori") {
		fingerprint.SatoriMatches = append(fingerprint.SatoriMatches, &netprobepb.SatoriFingerprintMatch{
			Axis:      protocol,
			Signature: strings.TrimSpace(match.GetRawPatternId()),
			Label:     strings.TrimSpace(match.GetProduct()),
			OsFamily:  strings.TrimSpace(match.GetOsFamily()),
		})
	}

	return &netprobepb.FingerprintEvent{
		Ip:                 strings.TrimSpace(observation.Host),
		ProfileId:          strings.TrimSpace(observation.Source),
		ObservedAtUnixNano: observation.ObservedAt.UnixNano(),
		Evidence: &netprobepb.FingerprintEvent_LicenseClean{
			LicenseClean: fingerprint,
		},
	}
}
