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

package banner_grab

import (
	"context"
	"net"
	"strconv"
	"time"
)

const (
	ProtocolSSH    = "ssh"
	ProtocolHTTP   = "http"
	ProtocolSMB    = "smb"
	ProtocolFTP    = "ftp"
	ProtocolTelnet = "telnet"
	ProtocolSMTP   = "smtp"
	ProtocolNTP    = "ntp"
	ProtocolDNS    = "dns"
	ProtocolRDP    = "rdp"

	SourceSweepActive = "sweep_active"
)

type DialContextFunc func(context.Context, string, string) (net.Conn, error)

// ProbeOpts carries bounded I/O settings for one active banner probe.
type ProbeOpts struct {
	ConnectTimeout time.Duration
	ReadTimeout    time.Duration
	MaxBannerBytes int
	DialContext    DialContextFunc
	Now            func() time.Time
}

// Candidate is a SYN-confirmed live host/port selected for active probing.
type Candidate struct {
	Host     string
	Port     int
	Protocol string
	Source   string
}

// BannerObservation is the compact application-byte record sent to netprobe.
type BannerObservation struct {
	ObservationID uint64    `json:"observation_id"`
	Host          string    `json:"host"`
	Port          int       `json:"port"`
	Protocol      string    `json:"protocol"`
	BannerBytes   []byte    `json:"banner_bytes"`
	ObservedAt    time.Time `json:"observed_at"`
	Source        string    `json:"source"`
}

type ProbeFunc func(context.Context, string, int, ProbeOpts) (BannerObservation, error)

func nowFromOpts(opts ProbeOpts) time.Time {
	if opts.Now != nil {
		return opts.Now()
	}

	return time.Now()
}

func dialWithTimeout(ctx context.Context, network, host string, port int, opts ProbeOpts) (net.Conn, error) {
	dialCtx := ctx
	cancel := func() {}

	if opts.ConnectTimeout > 0 {
		dialCtx, cancel = context.WithTimeout(ctx, opts.ConnectTimeout)
	}
	defer cancel()

	dialContext := opts.DialContext
	if dialContext == nil {
		dialer := &net.Dialer{}
		dialContext = dialer.DialContext
	}

	return dialContext(dialCtx, network, net.JoinHostPort(host, portString(port)))
}

func portString(port int) string {
	return strconv.Itoa(port)
}

func makeObservation(host string, port int, protocol string, banner []byte, opts ProbeOpts) BannerObservation {
	source := SourceSweepActive

	return BannerObservation{
		Host:        host,
		Port:        port,
		Protocol:    protocol,
		BannerBytes: append([]byte(nil), banner...),
		ObservedAt:  nowFromOpts(opts),
		Source:      source,
	}
}
