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
	"encoding/binary"
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

// runRingReader hands every frame the ring delivers to processEthernetFrame
// until ctx ends, the wake descriptor fires, or the ring socket fails.
func (s *SYNScanner) runRingReader(ctx context.Context, r *ringBuf) {
	if r == nil || r.blockNr == 0 {
		return
	}

	pfd := s.ringPollFDs(r)
	cur := atomic.LoadUint32(&r.cursor) % r.blockNr

	for {
		// First, drain any ready blocks without polling
		drained, canceled := s.drainReadyRingBlocks(ctx, r, &cur)
		if canceled {
			return
		}

		if drained {
			continue // see if more blocks are ready without poll
		}

		_, err := unix.Poll(pfd, s.ringPollTimeout())
		if err != nil {
			// EINTR and EAGAIN are fine; anything else, exit this reader
			if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
				continue
			}

			s.logger.Error().Err(err).Int("ring_fd", r.fd).Msg("Ring reader poll error, terminating reader.")

			return
		}

		if s.ringReaderDone(pfd) {
			return
		}
	}
}

// ringPollFDs is the poll set of a ring reader: the ring socket, plus the wake
// descriptor that signals cancellation when the scanner has one.
func (s *SYNScanner) ringPollFDs(r *ringBuf) []unix.PollFd {
	ring := unix.PollFd{Fd: int32(r.fd), Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLNVAL}
	if s.wakeFD > 0 {
		return []unix.PollFd{ring, {Fd: int32(s.wakeFD), Events: unix.POLLIN}}
	}

	return []unix.PollFd{ring}
}

// drainReadyRingBlocks processes every block the kernel has handed to user
// space, starting at *cur, and returns each to the kernel. It reports whether
// it processed any block, and whether ctx ended.
func (s *SYNScanner) drainReadyRingBlocks(ctx context.Context, r *ringBuf, cur *uint32) (drained, canceled bool) {
	for {
		select {
		case <-ctx.Done():
			return drained, true
		default:
		}

		blk := r.block(*cur)
		if blk == nil || len(blk) < int(h1_first_pkt_off+uint32Size) {
			return drained, false
		}

		status := loadU32(blk)
		if status&tpStatusUser == 0 {
			return drained, false // no more ready blocks
		}

		// Check for TP_STATUS_LOSING - indicates buffer overrun/dropped block
		if status&tpStatusLosing != 0 {
			atomic.AddUint64(&s.stats.RingBlocksDropped, 1)
		}

		s.processRingBlock(blk)

		// hand ownership back
		storeU32(blk, h1_status_off, 0)

		*cur = (*cur + 1) % r.blockNr
		atomic.StoreUint32(&r.cursor, *cur)
		drained = true

		// Update stats counter for each processed block
		atomic.AddUint64(&s.stats.RingBlocksProcessed, 1)
	}
}

// processRingBlock hands each frame of one ready TPACKET_V3 block to
// processEthernetFrame, stopping at the first header that does not fit.
func (s *SYNScanner) processRingBlock(blk []byte) {
	numPkts := binary.NativeEndian.Uint32(blk[h1_num_pkts_off : h1_num_pkts_off+4])
	first := binary.NativeEndian.Uint32(blk[h1_first_pkt_off : h1_first_pkt_off+4])

	if int(first) < 0 || int(first) >= len(blk) || numPkts == 0 {
		return
	}

	off := int(first)

	for p := uint32(0); p < numPkts; p++ {
		if off+int(pkt_mac_off+2) > len(blk) {
			return
		}

		ph := blk[off:]

		if int(pkt_next_off+uint32Size) > len(ph) ||
			int(pkt_snaplen_off+uint32Size) > len(ph) ||
			int(pkt_mac_off+2) > len(ph) {
			return
		}

		snap := int(binary.NativeEndian.Uint32(ph[pkt_snaplen_off : pkt_snaplen_off+4]))
		mac := int(binary.NativeEndian.Uint16(ph[pkt_mac_off : pkt_mac_off+2]))

		if mac >= 0 && snap >= 0 && mac+snap <= len(ph) {
			s.processEthernetFrame(ph[mac : mac+snap])
		}

		next := int(binary.NativeEndian.Uint32(ph[pkt_next_off : pkt_next_off+4]))
		if next <= 0 || off+next > len(blk) {
			return
		}

		off += next
	}
}

// ringPollTimeout is how long a ring reader blocks in poll when no block is
// ready. With a wake descriptor it blocks indefinitely and is woken on
// cancellation; otherwise it uses the configured timeout, falling back to
// max(retireTovMs, 50ms).
func (s *SYNScanner) ringPollTimeout() int {
	if s.wakeFD > 0 {
		return -1
	}

	if s.ringPollTimeoutMs > 0 {
		return s.ringPollTimeoutMs
	}

	return max(int(s.retireTovMs), 50)
}

// ringReaderDone reports whether a ring reader must exit after a poll: the
// wake descriptor fired (it is drained here) or the ring socket is in an error
// state.
func (s *SYNScanner) ringReaderDone(pfd []unix.PollFd) bool {
	// If wakeFD fired, drain it and exit (context likely canceled)
	if s.wakeFD > 0 && len(pfd) > 1 && (pfd[1].Revents&unix.POLLIN) != 0 {
		var buf [8]byte

		_, _ = unix.Read(s.wakeFD, buf[:])

		return true
	}

	// Check for socket errors after successful poll
	return pfd[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0
}
