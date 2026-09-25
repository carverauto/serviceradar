package mtr

func newTestRawSocket(fd int) RawSocket {
	return &linuxRawSocket{sendFD: fd}
}
