//go:build linux
// +build linux

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

package scan

import (
	"errors"
	"runtime"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

func (s *SYNScanner) sendSynBatchFamily(socket int, familyEntries []synBatchEntry, ipv6 bool) []synBatchEntry {
	if len(familyEntries) == 0 || socket == 0 {
		for _, entry := range familyEntries {
			s.tryReleaseMapping(entry.srcPort, entry.targetKey)
		}

		return nil
	}

	ba := s.batchPool.Get().(*batchArrays)
	defer func() {
		ba.addrs = ba.addrs[:0]
		ba.addrs6 = ba.addrs6[:0]
		ba.iovecs = ba.iovecs[:0]
		ba.hdrs = ba.hdrs[:0]
		s.batchPool.Put(ba)
	}()

	s.prepareBatchMessageArrays(ba, familyEntries, ipv6)
	off := s.sendBatchMessages(socket, ba.hdrs, ipv6)

	runtime.KeepAlive(ba.hdrs)
	runtime.KeepAlive(ba.iovecs)
	runtime.KeepAlive(ba.addrs)
	runtime.KeepAlive(ba.addrs6)
	runtime.KeepAlive(familyEntries)

	for i := range familyEntries {
		if familyEntries[i].pooled {
			s.packetPool.Put(familyEntries[i].packet) //nolint:staticcheck // slice is reference type, Put accepts interface{}
		}
	}

	for i := off; i < len(familyEntries); i++ {
		s.tryReleaseMapping(familyEntries[i].srcPort, familyEntries[i].targetKey)
	}

	return familyEntries[:off]
}

func (s *SYNScanner) prepareBatchMessageArrays(ba *batchArrays, familyEntries []synBatchEntry, ipv6 bool) {
	if cap(ba.iovecs) < len(familyEntries) {
		ba.iovecs = make([]unix.Iovec, len(familyEntries))
		ba.hdrs = make([]Mmsghdr, len(familyEntries))
	} else {
		ba.iovecs = ba.iovecs[:len(familyEntries)]
		ba.hdrs = ba.hdrs[:len(familyEntries)]
	}

	if ipv6 {
		if cap(ba.addrs6) < len(familyEntries) {
			ba.addrs6 = make([]unix.RawSockaddrInet6, len(familyEntries))
		} else {
			ba.addrs6 = ba.addrs6[:len(familyEntries)]
		}
	} else {
		if cap(ba.addrs) < len(familyEntries) {
			ba.addrs = make([]unix.RawSockaddrInet4, len(familyEntries))
		} else {
			ba.addrs = ba.addrs[:len(familyEntries)]
		}
	}

	for i := range familyEntries {
		if ipv6 {
			ba.addrs6[i] = unix.RawSockaddrInet6{
				Family: unix.AF_INET6,
				Port:   0,
				Addr:   familyEntries[i].dst6,
			}
			ba.hdrs[i].Hdr.Name = (*byte)(unsafe.Pointer(&ba.addrs6[i]))
			ba.hdrs[i].Hdr.Namelen = uint32(unsafe.Sizeof(ba.addrs6[i]))
		} else {
			ba.addrs[i] = unix.RawSockaddrInet4{
				Family: unix.AF_INET,
				Port:   0, // ignored by kernel for raw sockets with IP_HDRINCL
				Addr:   familyEntries[i].dst4,
			}
			ba.hdrs[i].Hdr.Name = (*byte)(unsafe.Pointer(&ba.addrs[i]))
			ba.hdrs[i].Hdr.Namelen = uint32(unsafe.Sizeof(ba.addrs[i]))
		}

		ba.iovecs[i].Base = &familyEntries[i].packet[0]
		ba.iovecs[i].SetLen(len(familyEntries[i].packet))
		ba.hdrs[i].Hdr.Iov = &ba.iovecs[i]
		ba.hdrs[i].Hdr.SetIovlen(1)
	}
}

func (s *SYNScanner) sendBatchMessages(socket int, hdrs []Mmsghdr, ipv6 bool) int {
	off := 0
	for off < len(hdrs) {
		n, err := sendmmsg(socket, hdrs[off:], 0)
		if n > 0 {
			off += n
			atomic.AddUint64(&s.stats.PacketsSent, uint64(n))
		}

		if err == nil {
			continue
		}

		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EINTR) {
			runtime.Gosched()
			continue
		}

		s.logger.Debug().Err(err).Bool("ipv6", ipv6).Int("remaining", len(hdrs)-off).Msg("sendmmsg failed; releasing unsent ports")
		break
	}

	return off
}
