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

package armis

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// retryPolicy bounds the retries of one Armis request. A sync run issues one
// search request per page, so without retries a single dropped connection or
// throttled response on any page ended the whole run as partial.
//
// The defaults follow the agent's other transient-download retry
// (release_update.go: 1s initial, 15s cap): a few seconds covers a load
// balancer blip, a backend pod restart or a short rate-limit window, and the
// per-request budget keeps a dead endpoint from holding the run for long. The
// run's own deadline (defaultSyncTimeout) still applies on top of it.
type retryPolicy struct {
	// maxAttempts counts every attempt, the first one included.
	maxAttempts int
	// baseDelay is the wait before the second attempt; it doubles per
	// attempt up to maxDelay, with equal jitter.
	baseDelay time.Duration
	maxDelay  time.Duration
	// budget bounds the wall-clock time from the first attempt to the start
	// of the last one. A retry whose wait would cross it is not taken.
	budget time.Duration
}

func defaultRetryPolicy() retryPolicy {
	return retryPolicy{
		maxAttempts: 5,
		baseDelay:   time.Second,
		maxDelay:    15 * time.Second,
		budget:      2 * time.Minute,
	}
}

// requestOp names a request in retry logs. from is logged only for paged
// search requests.
type requestOp struct {
	name  string
	paged bool
	from  int
}

// requestRetrier retries transient Armis request failures for one sync run.
// A nil retrier performs each request exactly once.
type requestRetrier struct {
	policy    retryPolicy
	sleep     func(context.Context, time.Duration) error
	logger    logger.Logger
	sourceKey string
	runID     string
}

// retryCall runs call, retrying transient failures under r's policy. It never
// retries a non-transient error, and it stops as soon as ctx is done. When
// retries run out the last error is returned, so the caller reports the run
// partial exactly as it would have without a retry.
func retryCall[T any](ctx context.Context, r *requestRetrier, op requestOp, call func() (T, error)) (T, error) {
	start := time.Now()
	result, err := call()
	if r == nil {
		return result, err
	}

	for attempt := 1; err != nil; attempt++ {
		reason, transient := transientReason(err)
		if !transient || ctx.Err() != nil {
			return result, err
		}
		if attempt >= r.policy.maxAttempts {
			return result, fmt.Errorf("armis %s gave up after %d attempts: %w", op.name, attempt, err)
		}

		wait := r.policy.wait(attempt, err)
		if elapsed := time.Since(start); elapsed+wait > r.policy.budget {
			return result, fmt.Errorf(
				"armis %s gave up after %d attempts (next wait %s exceeds the %s retry budget): %w",
				op.name, attempt, wait, r.policy.budget, err,
			)
		}

		r.logRetry(op, attempt, reason, wait, err)
		if sleepErr := r.sleep(ctx, wait); sleepErr != nil {
			return result, fmt.Errorf("%w; armis %s retry interrupted: %w", err, op.name, sleepErr)
		}

		result, err = call()
	}

	return result, nil
}

func (r *requestRetrier) logRetry(op requestOp, attempt int, reason string, wait time.Duration, err error) {
	event := r.logger.Warn().
		Err(err).
		Str("source", r.sourceKey).
		Str("run_id", r.runID).
		Str("operation", op.name).
		Int("attempt", attempt).
		Int("max_attempts", r.policy.maxAttempts).
		Str("reason", reason).
		Dur("wait", wait)
	if op.paged {
		event = event.Int("from", op.from)
	}
	event.Msg("Armis request failed transiently; retrying")
}

// wait is the delay after the given failed attempt (1-based): exponential
// backoff with equal jitter so agents sharing a tenant do not retry in
// lockstep, never shorter than a server-supplied Retry-After.
func (p retryPolicy) wait(attempt int, err error) time.Duration {
	backoff := p.baseDelay
	for i := 1; i < attempt && backoff < p.maxDelay; i++ {
		backoff *= 2
	}
	backoff = min(backoff, p.maxDelay)
	if half := backoff / 2; half > 0 {
		backoff = half + rand.N(half+1)
	}

	var reqErr *requestError
	if errors.As(err, &reqErr) && reqErr.retryAfter > backoff {
		return reqErr.retryAfter
	}

	return backoff
}

func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// transientReason reports whether err is worth retrying and names its class
// for the retry log. Throttling and gateway/availability statuses and
// transport failures (refused, reset, timed out, cut off) are transient.
// Every other HTTP status, including 401/403, and every response that
// arrived but did not decode are not: repeating them returns the same answer.
func transientReason(err error) (string, bool) {
	var reqErr *requestError
	if errors.As(err, &reqErr) {
		switch reqErr.statusCode {
		case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusBadGateway,
			http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return "http_" + strconv.Itoa(reqErr.statusCode), true
		default:
			return "", false
		}
	}

	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns", dnsErr.IsTimeout || dnsErr.IsTemporary
	}

	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "timeout", true
	}

	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return "connection_refused", true
	case errors.Is(err, syscall.ECONNRESET):
		return "connection_reset", true
	}

	// The server closed the connection before answering. Only an EOF the
	// HTTP client reports counts: an EOF from decoding a response body that
	// did arrive is an empty or truncated (malformed) response.
	var urlErr *url.Error
	if errors.As(err, &urlErr) && (errors.Is(urlErr.Err, io.EOF) || errors.Is(urlErr.Err, io.ErrUnexpectedEOF)) {
		return "connection_closed", true
	}

	// A dial, read or write failure whose errno is platform-specific (the
	// Windows WSA codes do not match the syscall constants above).
	var opErr *net.OpError
	for cause := err; errors.As(cause, &opErr); cause = opErr.Err {
		if opErr.Op == "dial" || opErr.Op == "read" || opErr.Op == "write" {
			return "connection_" + opErr.Op, true
		}
	}

	return "", false
}

const maxRetryAfterSeconds = 24 * 60 * 60

// parseRetryAfter reads a Retry-After header given in delta-seconds or as an
// HTTP date. An absent, malformed or past value yields zero.
func parseRetryAfter(value string, now time.Time) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if seconds, err := strconv.Atoi(value); err == nil {
		// Clamp before converting so a huge value cannot overflow; any wait
		// this long already exceeds the retry budget.
		return time.Duration(min(max(seconds, 0), maxRetryAfterSeconds)) * time.Second
	}
	if at, err := http.ParseTime(value); err == nil {
		return max(at.Sub(now), 0)
	}

	return 0
}
