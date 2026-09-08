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

package netprobe

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	// matchBannersAction and matchBannersSchema must equal netprobe's
	// banner_command::MATCH_BANNERS_ACTION / MATCH_BANNERS_SCHEMA. netprobe
	// refuses a schema it does not implement rather than decoding it as v1, so a
	// drift here is a loud refusal rather than a wrong answer.
	matchBannersAction = "match_banners"
	matchBannersSchema = "serviceradar.netprobe.banner_match.v1"

	addonRunCommandType = "addon.run_command"
)

// ErrAddonCommandUnavailable reports that netprobe is not serving the generic
// command contract on this host, which is the expected state while an older
// netprobe is still deployed. Callers fall back to the legacy IPC arm.
var ErrAddonCommandUnavailable = errors.New("netprobe AddonService command socket unavailable")

// ErrAddonCommandRefused reports that netprobe answered and DECLINED the command
// -- an unknown action, an unimplemented schema, or a payload it could not parse.
// Deliberately distinct from ErrAddonCommandUnavailable: conflating "the add-on
// is not there" with "the add-on rejected us" would let a genuine contract break
// hide as an un-upgraded netprobe for as long as the fallback keeps working.
var ErrAddonCommandRefused = errors.New("netprobe refused the addon command")

// AddonCommandClient calls netprobe's AddonService.RunCommand.
//
// This is the generic-contract replacement for the NetprobeFrame.BannerBatch IPC
// arm -- the last functional request/response arm on the bespoke socket, so it is
// what lets that socket be retired.
//
// The connection is created lazily and reused: a sweep flushes a banner batch
// every 500ms, and grpc.ClientConn is a managed channel that re-dials on its own,
// so one conn outlives a netprobe restart without the caller noticing.
type AddonCommandClient struct {
	socketPath string

	mu   sync.Mutex
	conn *grpc.ClientConn
}

func NewAddonCommandClient(socketPath string) *AddonCommandClient {
	return &AddonCommandClient{socketPath: socketPath}
}

// Close releases the shared connection.
func (c *AddonCommandClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return nil
	}

	conn := c.conn
	c.conn = nil

	return conn.Close()
}

func (c *AddonCommandClient) client() (addonpb.AddonServiceClient, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		// Checked before dialing so a netprobe that predates the contract reports
		// "unavailable" once, rather than a managed channel retrying a path that
		// will never exist.
		if _, err := os.Stat(c.socketPath); err != nil {
			return nil, fmt.Errorf("%w: %w", ErrAddonCommandUnavailable, err)
		}

		// The unix:// resolver, NOT passthrough:/// with a custom dialer: the
		// latter puts the socket path into the HTTP/2 :authority header and every
		// RPC dies with RST_STREAM PROTOCOL_ERROR.
		conn, err := grpc.NewClient(
			"unix://"+c.socketPath,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrAddonCommandUnavailable, err)
		}

		c.conn = conn
	}

	return addonpb.NewAddonServiceClient(c.conn), nil
}

// MatchBanners runs corpus matching over the generic command contract.
//
// The returned batch is deliberately shaped like the IPC arm's response so the
// caller's translation is identical on both paths -- except that netprobe now
// omits misses instead of padding them with a zero-confidence "unknown", so the
// result is NOT positionally aligned with the request. Callers already join on
// ObservationId.
func (c *AddonCommandClient) MatchBanners(
	ctx context.Context,
	batch *netprobepb.BannerBatch,
) (*netprobepb.BannerMatchBatch, error) {
	client, err := c.client()
	if err != nil {
		return nil, err
	}

	payload, err := json.Marshal(encodeBannerMatchRequest(batch))
	if err != nil {
		return nil, fmt.Errorf("encode match_banners payload: %w", err)
	}

	response, err := client.RunCommand(ctx, &addonpb.RunCommandRequest{
		// command_id is empty by design: this invocation is agent-originated, not
		// scheduled by the commandbus, and inventing an id would make it look like
		// a platform command in netprobe's logs.
		CommandType: addonRunCommandType,
		ActionId:    matchBannersAction,
		Schema:      matchBannersSchema,
		PayloadJson: payload,
	})
	if err != nil {
		return nil, err
	}

	if !response.GetSuccess() {
		return nil, fmt.Errorf("%w: %s: %s", ErrAddonCommandRefused, matchBannersAction, response.GetMessage())
	}

	return decodeBannerMatchResponse(response.GetPayloadJson())
}

type bannerMatchRequest struct {
	Observations []bannerMatchRequestObservation `json:"observations"`
}

type bannerMatchRequestObservation struct {
	ObservationID uint64 `json:"observation_id"`
	Protocol      string `json:"protocol"`
	// []byte, so encoding/json emits standard base64 WITH padding -- byte-for-byte
	// what Rust's base64 STANDARD engine decodes. Banners are binary (SMB, RDP,
	// DNS, NTP), and a plain string would round-trip them through two different
	// lossy-UTF-8 replacement rules and silently change the corpus match.
	BannerBytes []byte `json:"banner_b64"`
}

type bannerMatchResponse struct {
	Matches      []bannerMatchResponseMatch `json:"matches"`
	Observations int                        `json:"observations"`
}

type bannerMatchResponseMatch struct {
	ObservationID uint64  `json:"observation_id"`
	CorpusLabel   string  `json:"corpus_label"`
	OSFamily      string  `json:"os_family"`
	Product       string  `json:"product"`
	Version       string  `json:"version"`
	Confidence    float64 `json:"confidence"`
	RawPatternID  string  `json:"raw_pattern_id"`
}

func encodeBannerMatchRequest(batch *netprobepb.BannerBatch) bannerMatchRequest {
	observations := batch.GetObservations()
	out := bannerMatchRequest{
		Observations: make([]bannerMatchRequestObservation, 0, len(observations)),
	}

	for _, observation := range observations {
		if observation == nil {
			continue
		}

		// Only the three fields the matcher reads travel. host, port, source and
		// observed_at stay here: the caller re-attaches them from its own record
		// when it builds the fingerprint event, so sending them would create a
		// second source of truth for the same observation.
		out.Observations = append(out.Observations, bannerMatchRequestObservation{
			ObservationID: observation.GetObservationId(),
			Protocol:      observation.GetProtocol(),
			BannerBytes:   observation.GetBannerBytes(),
		})
	}

	return out
}

func decodeBannerMatchResponse(payload []byte) (*netprobepb.BannerMatchBatch, error) {
	var decoded bannerMatchResponse
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, fmt.Errorf("decode match_banners response: %w", err)
	}

	out := &netprobepb.BannerMatchBatch{
		Matches: make([]*netprobepb.BannerMatch, 0, len(decoded.Matches)),
	}

	for _, matched := range decoded.Matches {
		out.Matches = append(out.Matches, &netprobepb.BannerMatch{
			ObservationId: matched.ObservationID,
			CorpusLabel:   matched.CorpusLabel,
			OsFamily:      matched.OSFamily,
			Product:       matched.Product,
			Version:       matched.Version,
			Confidence:    matched.Confidence,
			RawPatternId:  matched.RawPatternID,
		})
	}

	return out, nil
}
