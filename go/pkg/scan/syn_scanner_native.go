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
	"encoding/binary"
	"sync/atomic"
	"unsafe"
)

func u32ptr(b []byte, off int) *uint32 {
	return (*uint32)(unsafe.Pointer(&b[off]))
}

// loadU32 performs an atomic load, which acts as an "acquire" memory barrier.
func loadU32(b []byte, off int) uint32 {
	// Defensive check to prevent out-of-bounds access
	if off < 0 || off+4 > len(b) {
		return 0
	}

	return atomic.LoadUint32(u32ptr(b, off))
}

// storeU32 performs an atomic store, which acts as a "release" memory barrier.
func storeU32(b []byte, off int, v uint32) {
	// Defensive check to prevent out-of-bounds access
	if off < 0 || off+4 > len(b) {
		return
	}

	atomic.StoreUint32(u32ptr(b, off), v)
}

// Host-endian detector for tpacket headers (host-endian on Linux)
//
//nolint:gochecknoglobals // performance optimization, computed once at startup
var hostEndian = func() binary.ByteOrder {
	var x uint16 = 0x0102

	b := *(*[2]byte)(unsafe.Pointer(&x))

	if b[0] == ipv4ProtocolCheck {
		return binary.BigEndian
	}

	return binary.LittleEndian
}()

// Host to network short/long byte order conversions
func htons(n uint16) uint16 {
	if hostEndian == binary.LittleEndian {
		return (n << 8) | (n >> 8)
	}

	return n
}
