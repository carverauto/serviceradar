package sdk

import (
	"context"
	"time"
)

// UDPSendTo sends a UDP payload via the host proxy.
func UDPSendTo(host string, port uint16, payload []byte, timeout time.Duration) error {
	return UDPSendToContext(context.Background(), host, port, payload, timeout)
}

// UDPSendToContext sends a UDP payload via the host proxy with a context.
func UDPSendToContext(ctx context.Context, host string, port uint16, payload []byte, timeout time.Duration) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}

	addr := []byte(host)

	res := hostUDPSendTo(
		ptrFromBytes(addr),
		uint32(len(addr)),
		uint32(port),
		ptrFromBytes(payload),
		uint32(len(payload)),
		uint32(timeout.Milliseconds()),
	)

	return hostErr(res, "udp_sendto")
}
