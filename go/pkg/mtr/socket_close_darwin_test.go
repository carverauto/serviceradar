package mtr

func newTestRawSocket(fd int) RawSocket {
	return &darwinRawSocket{sendFD: fd}
}
