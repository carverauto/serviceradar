package sdk

import (
	"context"
	"errors"
	"net"
	"os"
	"time"
)

var errTCPConnNotInitialized = errors.New("tcp connection not initialized")

// TCPConn wraps a host TCP connection handle.
type TCPConn struct {
	handle uint32
}

// NetConn exposes the host TCP connection as a net.Conn for TLS wrappers.
func (c *TCPConn) NetConn() net.Conn {
	return &hostNetConn{conn: c}
}

// TCPDial opens a TCP connection via the host proxy.
func TCPDial(host string, port uint16, timeout time.Duration) (*TCPConn, error) {
	return TCPDialContext(context.Background(), host, port, timeout)
}

// TCPDialContext opens a TCP connection via the host proxy with a context.
func TCPDialContext(ctx context.Context, host string, port uint16, timeout time.Duration) (*TCPConn, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	addr := []byte(host)
	res := hostTCPConnect(ptrFromBytes(addr), uint32(len(addr)), uint32(port), uint32(timeout.Milliseconds()))

	if res < 0 {
		return nil, hostErr(res, "tcp_connect")
	}
	return &TCPConn{handle: uint32(res)}, nil
}

// Read reads from the host connection into buf.
func (c *TCPConn) Read(buf []byte, timeout time.Duration) (int, error) {
	return c.ReadContext(context.Background(), buf, timeout)
}

// ReadContext reads from the host connection into buf with a context.
func (c *TCPConn) ReadContext(ctx context.Context, buf []byte, timeout time.Duration) (int, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
	}

	if c == nil || c.handle == 0 {
		return 0, errTCPConnNotInitialized
	}
	if len(buf) == 0 {
		return 0, nil
	}

	res := hostTCPRead(c.handle, ptrFromBytes(buf), uint32(len(buf)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return 0, hostErr(res, "tcp_read")
	}

	return int(res), nil
}

// Write writes data to the host connection.
func (c *TCPConn) Write(data []byte, timeout time.Duration) (int, error) {
	return c.WriteContext(context.Background(), data, timeout)
}

// WriteContext writes data to the host connection with a context.
func (c *TCPConn) WriteContext(ctx context.Context, data []byte, timeout time.Duration) (int, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
	}

	if c == nil || c.handle == 0 {
		return 0, errTCPConnNotInitialized
	}
	if len(data) == 0 {
		return 0, nil
	}

	res := hostTCPWrite(c.handle, ptrFromBytes(data), uint32(len(data)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return 0, hostErr(res, "tcp_write")
	}

	return int(res), nil
}

// Close closes the host connection.
func (c *TCPConn) Close() error {
	if c == nil || c.handle == 0 {
		return nil
	}
	res := hostTCPClose(c.handle)

	c.handle = 0

	return hostErr(res, "tcp_close")
}

type hostNetConn struct {
	conn          *TCPConn
	readDeadline  time.Time
	writeDeadline time.Time
}

func (c *hostNetConn) Read(buf []byte) (int, error) {
	timeout, err := timeoutUntil(c.readDeadline)
	if err != nil {
		return 0, err
	}

	return c.conn.Read(buf, timeout)
}

func (c *hostNetConn) Write(data []byte) (int, error) {
	timeout, err := timeoutUntil(c.writeDeadline)
	if err != nil {
		return 0, err
	}

	return c.conn.Write(data, timeout)
}

func (c *hostNetConn) Close() error {
	return c.conn.Close()
}

func (c *hostNetConn) LocalAddr() net.Addr {
	return &net.TCPAddr{}
}

func (c *hostNetConn) RemoteAddr() net.Addr {
	return &net.TCPAddr{}
}

func (c *hostNetConn) SetDeadline(t time.Time) error {
	c.readDeadline = t
	c.writeDeadline = t
	return nil
}

func (c *hostNetConn) SetReadDeadline(t time.Time) error {
	c.readDeadline = t
	return nil
}

func (c *hostNetConn) SetWriteDeadline(t time.Time) error {
	c.writeDeadline = t
	return nil
}

func timeoutUntil(deadline time.Time) (time.Duration, error) {
	if deadline.IsZero() {
		return 0, nil
	}

	timeout := time.Until(deadline)
	if timeout <= 0 {
		return 0, os.ErrDeadlineExceeded
	}

	return timeout, nil
}
