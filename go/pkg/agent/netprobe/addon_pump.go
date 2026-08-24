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
	"errors"
	"io"
	"os"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	defaultAddonPumpMinBackoff = time.Second
	defaultAddonPumpMaxBackoff = 30 * time.Second
)

var ErrAddonPumpNoSink = errors.New("netprobe addon pump requires a telemetry sink")

// AddonPumpConfig configures the AddonService telemetry pump.
type AddonPumpConfig struct {
	// SocketPath is netprobe's AddonService socket. Derived from the legacy IPC
	// socket by AttachAddonSocketPath, matching netprobe's own default.
	SocketPath string
	// Sink receives each batch verbatim. The pump deliberately does not decode
	// the payloads: a new payload schema must cost zero agent changes, which is
	// only true while the agent stays ignorant of what it is forwarding.
	Sink       func(*addonpb.TelemetryBatch)
	Logger     zerolog.Logger
	MinBackoff time.Duration
	MaxBackoff time.Duration
}

// AddonPump consumes netprobe's AddonService telemetry stream and forwards it to
// the agent's add-on telemetry buffer, the same one every launched add-on feeds.
type AddonPump struct {
	cfg AddonPumpConfig
}

func NewAddonPump(cfg AddonPumpConfig) (*AddonPump, error) {
	if cfg.Sink == nil {
		return nil, ErrAddonPumpNoSink
	}
	if cfg.MinBackoff <= 0 {
		cfg.MinBackoff = defaultAddonPumpMinBackoff
	}
	if cfg.MaxBackoff <= 0 {
		cfg.MaxBackoff = defaultAddonPumpMaxBackoff
	}

	return &AddonPump{cfg: cfg}, nil
}

// Run keeps a telemetry stream attached until ctx is cancelled.
//
// This is the ONLY path by which netprobe discovery reaches core -- census,
// mDNS, fingerprints, DPI and the process listing. The legacy IPC arms that
// carried them are gone, so a netprobe too old to serve AddonService reports no
// devices at all.
//
// That IS reachable, and an earlier version of this comment claimed otherwise:
// "the agent and the add-on ship and deploy together". They do not.
// addons/netprobe/addon.yaml declares `delivery: pushed-artifact` with its own
// version line and `base_agent: ">=1.2.0"` -- a FLOOR, which is an explicit
// statement that skew is permitted. A host can run a new agent against an old
// netprobe.
//
// Which is why the failure is loud rather than silent: the reconnect loop below
// logs at WARN, so an operator sees "no discovery is being collected" instead of
// a fleet that has quietly stopped reporting devices. Do not downgrade that to
// debug on the theory that it cannot happen.
func (p *AddonPump) Run(ctx context.Context) {
	backoff := p.cfg.MinBackoff

	for ctx.Err() == nil {
		delivered, err := p.session(ctx)

		if ctx.Err() != nil {
			return
		}

		switch {
		case delivered:
			// A stream that delivered before failing is a working contract with
			// a dropped connection, not an absent one. Reconnect promptly.
			backoff = p.cfg.MinBackoff
			p.cfg.Logger.Warn().Err(err).Msg("Netprobe AddonService stream ended; discovery is stalled until it reconnects")
		case err != nil:
			p.cfg.Logger.Warn().Err(err).Str("socket", p.cfg.SocketPath).
				Msg("Netprobe AddonService unavailable; no discovery is being collected")
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}

		if !delivered {
			backoff = min(backoff*2, p.cfg.MaxBackoff)
		}
	}
}

// session runs one connection. It reports whether any batch was delivered, which
// separates "netprobe does not serve this" from "the stream broke", and decides
// whether to reconnect promptly or keep backing off.
func (p *AddonPump) session(ctx context.Context) (bool, error) {
	// Checked before dialing so a netprobe that predates the contract produces a
	// clear stat error rather than a stream of connection failures.
	if _, err := os.Stat(p.cfg.SocketPath); err != nil {
		return false, err
	}

	// The unix:// resolver, NOT passthrough:/// with a custom dialer. The latter
	// puts the socket path (slashes and all) into the HTTP/2 :authority header
	// and every RPC dies with RST_STREAM PROTOCOL_ERROR.
	conn, err := grpc.NewClient("unix://"+p.cfg.SocketPath, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return false, err
	}
	defer func() { _ = conn.Close() }()

	stream, err := addonpb.NewAddonServiceClient(conn).StreamTelemetry(ctx, &addonpb.StreamTelemetryRequest{})
	if err != nil {
		return false, err
	}

	delivered := false
	for {
		batch, err := stream.Recv()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return delivered, nil
			}

			return delivered, err
		}

		if !delivered {
			delivered = true
			p.cfg.Logger.Info().Str("socket", p.cfg.SocketPath).
				Msg("Netprobe AddonService stream attached; discovery is flowing")
		}

		p.cfg.Sink(batch)
	}
}
