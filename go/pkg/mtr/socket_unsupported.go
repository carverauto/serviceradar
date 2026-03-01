//go:build !linux && !darwin && !windows

package mtr

import (
	"errors"
	"net"
	"time"
)

var errRawSocketUnsupported = errors.New("raw socket MTR probing is unsupported on this platform")

type unsupportedRawSocket struct{}

func NewRawSocket(_ bool) (RawSocket, error) {
	return nil, errRawSocketUnsupported
}

func (s *unsupportedRawSocket) SendICMP(_ net.IP, _ int, _ int, _ int, _ []byte) error {
	return errRawSocketUnsupported
}

func (s *unsupportedRawSocket) SendUDP(_ net.IP, _ int, _ int, _ int, _ []byte) error {
	return errRawSocketUnsupported
}

func (s *unsupportedRawSocket) SendTCP(_ net.IP, _ int, _ int, _ int) error {
	return errRawSocketUnsupported
}

func (s *unsupportedRawSocket) Receive(_ time.Time) (*ICMPResponse, error) {
	return nil, errRawSocketUnsupported
}

func (s *unsupportedRawSocket) Close() error {
	return nil
}

func (s *unsupportedRawSocket) IsIPv6() bool {
	return false
}
