package mtr

import "testing"

func TestICMPResponseReleaseClearsPooledPayload(t *testing.T) {
	t.Parallel()

	buf := getRecvBuffer(defaultRecvBufferSize)
	resp := &ICMPResponse{
		Payload: buf[:32],
		recvBuf: buf,
	}

	resp.Release()

	if resp.recvBuf != nil {
		t.Fatal("expected receive buffer to be released")
	}
	if resp.Payload != nil {
		t.Fatal("expected payload slice to be cleared after release")
	}
}
