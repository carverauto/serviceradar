//go:build !linux && !darwin

package mtr

import "errors"

var errRawSocketUnsupported = errors.New("raw socket MTR probing is unsupported on this platform")

// NewRawSocket reports that ICMP/UDP raw sockets are unavailable on this platform.
func NewRawSocket(_ bool) (RawSocket, error) {
	return nil, errRawSocketUnsupported
}
