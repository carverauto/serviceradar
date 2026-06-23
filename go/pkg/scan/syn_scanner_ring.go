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
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

// TPACKETv3 Ring
// Mirrors Linux's struct tpacket_req3 (all fields uint32)
type tpacketReq3 struct {
	BlockSize      uint32 // tp_block_size
	BlockNr        uint32 // tp_block_nr
	FrameSize      uint32 // tp_frame_size
	FrameNr        uint32 // tp_frame_nr
	RetireBlkTov   uint32 // tp_retire_blk_tov (ms)
	SizeofPriv     uint32 // tp_sizeof_priv
	FeatureReqWord uint32 // tp_feature_req_word
}

type ringBuf struct {
	fd        int
	mem       []byte
	blockSize uint32
	blockNr   uint32
	cursor    uint32
}

func setupTPacketV3(fd int, blockSize, blockNr, frameSize, retireMs uint32) (*ringBuf, error) {
	if err := unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_VERSION, unix.TPACKET_V3); err != nil {
		return nil, fmt.Errorf("PACKET_VERSION TPACKET_V3: %w", err)
	}

	req := tpacketReq3{
		BlockSize:    blockSize,
		BlockNr:      blockNr,
		FrameSize:    frameSize,
		FrameNr:      (blockSize / frameSize) * blockNr,
		RetireBlkTov: retireMs,
	}

	_, _, errno := unix.Syscall6(unix.SYS_SETSOCKOPT,
		uintptr(fd),
		uintptr(unix.SOL_PACKET),
		uintptr(unix.PACKET_RX_RING),
		uintptr(unsafe.Pointer(&req)),
		unsafe.Sizeof(req),
		0,
	)

	if errno != 0 {
		return nil, fmt.Errorf("PACKET_RX_RING: %w", errno)
	}

	total := int(blockSize * blockNr)

	mem, err := unix.Mmap(fd, 0, total, unix.PROT_READ|unix.PROT_WRITE, unix.MAP_SHARED)
	if err != nil {
		return nil, fmt.Errorf("mmap ring: %w", err)
	}

	return &ringBuf{fd: fd, mem: mem, blockSize: blockSize, blockNr: blockNr}, nil
}

// Offsets inside tpacket_block_desc.v3 (host-endian)
const (
	blk_version_off  = 0
	blk_off_priv_off = 4
	blk_h1_off       = blk_off_priv_off + 4 // 8

	h1_status_off    = blk_h1_off + 0  // u32 block_status
	h1_num_pkts_off  = blk_h1_off + 4  // u32 num_pkts
	h1_first_pkt_off = blk_h1_off + 8  // u32 offset_to_first_pkt
	h1_blk_len_off   = blk_h1_off + 12 // u32 blk_len
	h1_seq_off       = blk_h1_off + 16 // u64 seq_num
)

// Offsets inside struct tpacket3_hdr (host-endian)
const (
	pkt_next_off    = 0  // u32 tp_next_offset
	pkt_sec_off     = 4  // u32 tp_sec (unused)
	pkt_nsec_off    = 8  // u32 tp_nsec (unused)
	pkt_snaplen_off = 12 // u32 tp_snaplen
	pkt_len_off     = 16 // u32 tp_len (unused)
	pkt_status_off  = 20 // u32 tp_status (unused here)
	pkt_mac_off     = 24 // u16 tp_mac
	pkt_net_off     = 26 // u16 tp_net (unused)
)

func (r *ringBuf) block(i uint32) []byte {
	// Defensive checks for nil or invalid ring buffer
	if r == nil || r.mem == nil || len(r.mem) == 0 {
		return nil
	}

	base := int(i * r.blockSize)
	end := base + int(r.blockSize)

	if base < 0 || end > len(r.mem) || base >= end {
		return nil
	}

	return r.mem[base:end]
}

//nolint:gocyclo // Complex packet processing logic with inherent branching
func (s *SYNScanner) runRingReader(ctx context.Context, r *ringBuf) {
	if r == nil || r.blockNr == 0 {
		return
	}

	// Build pollfd set: ring FD + optional wake FD for cancellation
	var pfd []unix.PollFd
	if s.wakeFD > 0 {
		pfd = []unix.PollFd{
			{Fd: int32(r.fd), Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLNVAL},
			{Fd: int32(s.wakeFD), Events: unix.POLLIN},
		}
	} else {
		pfd = []unix.PollFd{{Fd: int32(r.fd), Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLNVAL}}
	}

	cur := atomic.LoadUint32(&r.cursor) % r.blockNr

	for {
		// First, drain any ready blocks without polling
		drained := false

		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			blk := r.block(cur)
			if blk == nil || len(blk) < int(h1_first_pkt_off+uint32Size) {
				break
			}

			status := loadU32(blk, h1_status_off)
			if status&tpStatusUser == 0 {
				break // no more ready blocks
			}

			// Check for TP_STATUS_LOSING - indicates buffer overrun/dropped block
			if status&tpStatusLosing != 0 {
				atomic.AddUint64(&s.stats.RingBlocksDropped, 1)
			}

			// process one ready block
			numPkts := hostEndian.Uint32(blk[h1_num_pkts_off : h1_num_pkts_off+4])
			first := hostEndian.Uint32(blk[h1_first_pkt_off : h1_first_pkt_off+4])

			if int(first) >= 0 && int(first) < len(blk) && numPkts > 0 {
				off := int(first)

				for p := uint32(0); p < numPkts; p++ {
					if off+int(pkt_mac_off+2) > len(blk) {
						break
					}

					ph := blk[off:]

					if int(pkt_next_off+uint32Size) > len(ph) ||
						int(pkt_snaplen_off+uint32Size) > len(ph) ||
						int(pkt_mac_off+2) > len(ph) {
						break
					}

					snap := int(hostEndian.Uint32(ph[pkt_snaplen_off : pkt_snaplen_off+4]))
					mac := int(hostEndian.Uint16(ph[pkt_mac_off : pkt_mac_off+2]))

					if mac >= 0 && snap >= 0 && mac+snap <= len(ph) {
						s.processEthernetFrame(ph[mac : mac+snap])
					}

					next := int(hostEndian.Uint32(ph[pkt_next_off : pkt_next_off+4]))
					if next <= 0 || off+next > len(blk) {
						break
					}

					off += next
				}
			}

			// hand ownership back
			storeU32(blk, h1_status_off, 0)

			cur = (cur + 1) % r.blockNr
			atomic.StoreUint32(&r.cursor, cur)
			drained = true

			// Update stats counter for each processed block
			atomic.AddUint64(&s.stats.RingBlocksProcessed, 1)
		}

		if drained {
			continue // see if more blocks are ready without poll
		}

		// Nothing ready; block in poll. If wakeFD is present, block indefinitely
		// and wake via eventfd on cancellation. Otherwise, use configured timeout.
		to := -1
		if s.wakeFD <= 0 {
			to = s.ringPollTimeoutMs
			if to <= 0 {
				to = int(s.retireTovMs)
				if to < 50 {
					to = 50
				}
			}
		}

		_, err := unix.Poll(pfd, to)
		if err != nil {
			// EINTR and EAGAIN are fine; anything else, exit this reader
			if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
				continue
			}

			s.logger.Error().Err(err).Int("ring_fd", r.fd).Msg("Ring reader poll error, terminating reader.")

			return
		}

		// If wakeFD fired, drain it and exit (context likely canceled)
		if s.wakeFD > 0 && len(pfd) > 1 && (pfd[1].Revents&unix.POLLIN) != 0 {
			var buf [8]byte

			_, _ = unix.Read(s.wakeFD, buf[:])

			return
		}

		// Check for socket errors after successful poll
		if pfd[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			// Socket is in error state, exit this reader
			return
		}
	}
}

// NewSYNScanner creates a new SYN scanner with custom options
//
// The scanner automatically detects a safe port range that doesn't conflict with
// the system's ephemeral ports or other local applications by reading:
// - /proc/sys/net/ipv4/ip_local_port_range (system ephemeral range)
// - /proc/sys/net/ipv4/ip_local_reserved_ports (reserved ports)
//
// Rate limiting guidance:
// Set rate limit to avoid source-port exhaustion. The available window depends
// on the detected safe range. Each port is in-flight for ~timeout+grace.
// Safe starting rate: pps ≈ window/(timeout+grace)
//
// Configure rate limit before starting a scan for best results, though SetRateLimit
// uses atomic.Value and is safe to call anytime, including during active scans.
//
// Example: scanner.SetRateLimit(20000, 5000) // 20k pps, 5k burst
