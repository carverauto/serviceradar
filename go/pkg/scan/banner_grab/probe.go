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
	"errors"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

func probeTCP(ctx context.Context, host string, port int, protocol string, payload []byte, opts ProbeOpts) (BannerObservation, error) {
	conn, err := dialWithTimeout(ctx, "tcp", host, port, opts)
	if err != nil {
		return BannerObservation{}, err
	}
	defer func() { _ = conn.Close() }()

	if opts.ReadTimeout > 0 {
		_ = conn.SetDeadline(time.Now().Add(opts.ReadTimeout))
	}

	if len(payload) > 0 {
		if _, err := conn.Write(payload); err != nil {
			return BannerObservation{}, err
		}
	}

	banner, err := readBanner(conn, opts.MaxBannerBytes)
	if err != nil {
		return BannerObservation{}, err
	}

	return makeObservation(host, port, protocol, banner, opts), nil
}

func probeUDP(ctx context.Context, host string, port int, protocol string, payload []byte, opts ProbeOpts) (BannerObservation, error) {
	conn, err := dialWithTimeout(ctx, "udp", host, port, opts)
	if err != nil {
		return BannerObservation{}, err
	}
	defer func() { _ = conn.Close() }()

	if opts.ReadTimeout > 0 {
		_ = conn.SetDeadline(time.Now().Add(opts.ReadTimeout))
	}

	if len(payload) > 0 {
		if _, err := conn.Write(payload); err != nil {
			return BannerObservation{}, err
		}
	}

	banner, err := readBanner(conn, opts.MaxBannerBytes)
	if err != nil {
		return BannerObservation{}, err
	}

	return makeObservation(host, port, protocol, banner, opts), nil
}

func readBanner(reader io.Reader, maxBytes int) ([]byte, error) {
	if maxBytes <= 0 {
		maxBytes = defaultMaxBannerBytes
	}

	buf := make([]byte, maxBytes)
	n, err := reader.Read(buf)
	if err != nil {
		if errors.Is(err, io.EOF) && n > 0 {
			return buf[:n], nil
		}

		return nil, err
	}

	return buf[:n], nil
}

func isTimeout(err error) bool {
	if err == nil {
		return false
	}

	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}

	var netErr net.Error

	return errors.As(err, &netErr) && netErr.Timeout()
}

func isReset(err error) bool {
	if err == nil {
		return false
	}

	if errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) {
		return true
	}

	text := strings.ToLower(err.Error())

	return strings.Contains(text, "connection reset") ||
		strings.Contains(text, "connection refused") ||
		strings.Contains(text, "reset by peer")
}
