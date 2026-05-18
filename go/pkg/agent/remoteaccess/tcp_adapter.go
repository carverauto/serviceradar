/*
 * Copyright 2025 Carver Automation Corporation.
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

package remoteaccess

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"
)

const defaultTCPReadChunkBytes = 32 * 1024

var (
	ErrTCPAdapterNil            = errors.New("tcp adapter is nil")
	ErrTCPDirectionNotAllowed   = errors.New("tcp frame direction not allowed")
	ErrTCPBytesInQuotaExceeded  = errors.New("tcp bytes in quota exceeded")
	ErrTCPBytesOutQuotaExceeded = errors.New("tcp bytes out quota exceeded")
	ErrTCPAdapterClosed         = errors.New("tcp adapter is closed")
	ErrInvalidTCPReadChunkSize  = errors.New("invalid tcp read chunk size")
)

type TCPDialer func(context.Context, string, string) (net.Conn, error)

type TCPAdapterOptions struct {
	DialContext TCPDialer
}

type TCPAdapter struct {
	open TCPOpenPayload
	conn net.Conn

	mu       sync.Mutex
	closed   bool
	bytesIn  int64
	bytesOut int64
	readSeq  uint64
}

func NewTCPAdapter(ctx context.Context, open TCPOpenPayload, opts TCPAdapterOptions) (*TCPAdapter, error) {
	if err := open.Validate(); err != nil {
		return nil, err
	}

	dialContext := opts.DialContext
	if dialContext == nil {
		dialContext = (&net.Dialer{}).DialContext
	}

	conn, err := dialContext(ctx, "tcp", net.JoinHostPort(open.UpstreamHost, strconv.Itoa(open.UpstreamPort)))
	if err != nil {
		return nil, err
	}

	adapter := &TCPAdapter{open: open, conn: conn}
	adapter.refreshDeadline()

	return adapter, nil
}

func (a *TCPAdapter) Write(frame TCPDataPayload) (TCPProgressPayload, error) {
	if a == nil {
		return TCPProgressPayload{}, ErrTCPAdapterNil
	}
	if err := frame.Validate(); err != nil {
		return TCPProgressPayload{}, err
	}
	if frame.Direction != TCPDataDirectionClient {
		return TCPProgressPayload{}, ErrTCPDirectionNotAllowed
	}

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return TCPProgressPayload{}, ErrTCPAdapterClosed
	}
	if max := maxTCPBytesIn(a.open.QuotaPolicy); max > 0 && a.bytesIn+int64(len(frame.Data)) > max {
		a.mu.Unlock()
		return TCPProgressPayload{}, ErrTCPBytesInQuotaExceeded
	}
	a.bytesIn += int64(len(frame.Data))
	bytesIn := a.bytesIn
	bytesOut := a.bytesOut
	a.refreshDeadlineLocked()
	a.mu.Unlock()

	if len(frame.Data) > 0 {
		if _, err := a.conn.Write(frame.Data); err != nil {
			return TCPProgressPayload{}, err
		}
	}

	if frame.EOF {
		_ = closeWrite(a.conn)
	}

	return TCPProgressPayload{
		SessionID:    a.open.SessionID,
		ConnectionID: a.open.ConnectionID,
		Status:       TCPStatusInProgress,
		BytesIn:      bytesIn,
		BytesOut:     bytesOut,
	}, nil
}

func (a *TCPAdapter) Read(ctx context.Context, maxChunkBytes int) (TCPDataPayload, TCPProgressPayload, error) {
	if a == nil {
		return TCPDataPayload{}, TCPProgressPayload{}, ErrTCPAdapterNil
	}
	if maxChunkBytes <= 0 {
		maxChunkBytes = defaultTCPReadChunkBytes
	}
	if maxChunkBytes > MaxTerminalFrameData {
		return TCPDataPayload{}, TCPProgressPayload{}, ErrInvalidTCPReadChunkSize
	}

	buffer := make([]byte, maxChunkBytes)
	for {
		if err := ctx.Err(); err != nil {
			return TCPDataPayload{}, TCPProgressPayload{}, err
		}

		n, err := a.conn.Read(buffer)
		if n > 0 {
			data := append([]byte(nil), buffer[:n]...)
			frame, progress, quotaErr := a.recordRead(data)
			if quotaErr != nil {
				return TCPDataPayload{}, progress, quotaErr
			}
			return frame, progress, nil
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				frame, progress := a.eofRead()
				return frame, progress, io.EOF
			}
			return TCPDataPayload{}, TCPProgressPayload{}, err
		}
	}
}

func (a *TCPAdapter) Close() error {
	if a == nil {
		return ErrTCPAdapterNil
	}

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return nil
	}
	a.closed = true
	a.mu.Unlock()

	return a.conn.Close()
}

func (a *TCPAdapter) recordRead(data []byte) (TCPDataPayload, TCPProgressPayload, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed {
		return TCPDataPayload{}, a.progressLocked(TCPStatusClosed), ErrTCPAdapterClosed
	}
	if max := maxTCPBytesOut(a.open.QuotaPolicy); max > 0 && a.bytesOut+int64(len(data)) > max {
		return TCPDataPayload{}, a.progressLocked(TCPStatusQuotaExhausted), ErrTCPBytesOutQuotaExceeded
	}

	a.bytesOut += int64(len(data))
	a.readSeq++
	a.refreshDeadlineLocked()

	return TCPDataPayload{
		SessionID:    a.open.SessionID,
		ConnectionID: a.open.ConnectionID,
		Direction:    TCPDataDirectionUpstream,
		Sequence:     a.readSeq,
		Data:         data,
	}, a.progressLocked(TCPStatusInProgress), nil
}

func (a *TCPAdapter) eofRead() (TCPDataPayload, TCPProgressPayload) {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.readSeq++

	return TCPDataPayload{
		SessionID:    a.open.SessionID,
		ConnectionID: a.open.ConnectionID,
		Direction:    TCPDataDirectionUpstream,
		Sequence:     a.readSeq,
		EOF:          true,
	}, a.progressLocked(TCPStatusCompleted)
}

func (a *TCPAdapter) progressLocked(status RemoteAccessStreamStatus) TCPProgressPayload {
	return TCPProgressPayload{
		SessionID:    a.open.SessionID,
		ConnectionID: a.open.ConnectionID,
		Status:       status,
		BytesIn:      a.bytesIn,
		BytesOut:     a.bytesOut,
	}
}

func (a *TCPAdapter) refreshDeadline() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.refreshDeadlineLocked()
}

func (a *TCPAdapter) refreshDeadlineLocked() {
	timeout := time.Duration(a.open.IdleTimeoutSeconds) * time.Second
	if timeout > 0 {
		_ = a.conn.SetDeadline(time.Now().Add(timeout))
	}
}

func maxTCPBytesIn(policy map[string]any) int64 {
	return positivePolicyInt64(policy, "max_bytes_in")
}

func maxTCPBytesOut(policy map[string]any) int64 {
	return positivePolicyInt64(policy, "max_bytes_out")
}

func closeWrite(conn net.Conn) error {
	type closeWriter interface {
		CloseWrite() error
	}
	if writer, ok := conn.(closeWriter); ok {
		return writer.CloseWrite()
	}

	return nil
}
