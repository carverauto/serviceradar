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
	"math/rand"
	"net"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe" // only for PACKET_RX_RING req pointer & tiny endianness probe

	"golang.org/x/sys/unix"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func init() {
	rand.Seed(time.Now().UnixNano())
}

const (
	// TCP flags
	synFlag = 0x02
	rstFlag = 0x04
	ackFlag = 0x10

	// Ephemeral port range start/end for source ports (dedicated range)
	ephemeralPortStart = 32768
	ephemeralPortEnd   = 61000

	// Network constants
	defaultTCPWindow = 65535
	maxPortNumber    = 65535

	// Ethernet type
	etherTypeIPv4 = 0x0800
	etherTypeVLAN = 0x8100
	etherTypeQinQ = 0x88A8
	etherType9100 = 0x9100 // common vendor tag

	// TPACKETv3 constants / defaults
	defaultBlockSize   = 1 << 20 // 1 MiB per block
	defaultBlockCount  = 8       // 8 MiB total ring (was 64 - overkill)
	defaultFrameSize   = 2048    // alignment hint
	defaultRetireTovMs = 30      // flush block to user within 30ms (optimized for low latency)

	// tpacket v3 block ownership
	tpStatusUser = 1 // TP_STATUS_USER
)

// u32ptr gets a pointer to a uint32 at a specific offset in a byte slice.
// mmap'd memory is shared; use atomics to enforce ordering with the kernel.
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
var hostEndian = func() binary.ByteOrder {
	var x uint16 = 0x0102

	b := *(*[2]byte)(unsafe.Pointer(&x))

	if b[0] == 0x01 {
		return binary.BigEndian
	}

	return binary.LittleEndian
}()

// SYNScanner performs SYN scanning (half-open scanning) for faster TCP port detection.
//
// For maximum accuracy, consider setting iptables rules to drop outbound RSTs from your
// ephemeral port range to prevent kernel interference:
//
//	iptables -A OUTPUT -p tcp --tcp-flags RST RST --sport 32768:61000 -j DROP
//
// or with nftables:
//
//	nft add rule inet filter output tcp flags rst tcp sport 32768-61000 drop
//
// This implementation sniffs replies via AF_PACKET + TPACKET_V3 ring (zero-copy),
// uses classic BPF to reduce userland traffic, and PACKET_FANOUT to scale across cores.
// Packet crafting uses raw IPv4+TCP with IP_HDRINCL (no unsafe, big-endian writes).
//
// Linux-only.
// https://www.kernel.org/doc/Documentation/networking/packet_mmap.txt
type SYNScanner struct {
	timeout     time.Duration
	concurrency int
	logger      logger.Logger

	sendSocket int // Raw IPv4 socket for sending (IP_HDRINCL enabled)
	rings      []*ringBuf
	cancel     context.CancelFunc

	sourceIP net.IP
	iface    string // Network interface name

	fanoutGroup int

	mu            sync.Mutex
	portTargetMap map[uint16]string  // Maps source port -> target key ("ip:port")
	targetIP      map[string][4]byte // target key -> dest IPv4 bytes
	results       map[string]models.Result

	portAlloc *PortAllocator

	retryAttempts  int           // e.g., 2
	retryMinJitter time.Duration // e.g., 20 * time.Millisecond
	retryMaxJitter time.Duration // e.g., 40 * time.Millisecond

	readersWG sync.WaitGroup // tracks the outer listener, which itself waits for all ring readers

	// Internal enqueue callback (set by Scan) and user callback (settable anytime).
	// Do NOT call user callback from ring threads; tee it in the emitter goroutine.
	resultCallback func(models.Result) // internal, owned by Scan
	userCallback   atomic.Value        // of type func(models.Result)
}

var _ Scanner = (*SYNScanner)(nil)

// Ethernet
type EthHdr struct {
	DstMAC    [6]byte
	SrcMAC    [6]byte
	EtherType uint16
}

func parseEthernet(b []byte) (*EthHdr, error) {
	if len(b) < 14 {
		return nil, fmt.Errorf("short ethernet frame")
	}

	h := &EthHdr{}

	copy(h.DstMAC[:], b[0:6])
	copy(h.SrcMAC[:], b[6:12])

	h.EtherType = binary.BigEndian.Uint16(b[12:14])

	return h, nil
}

// IPv4
type IPv4Hdr struct {
	IHL      uint8
	Protocol uint8
	SrcIP    net.IP
	DstIP    net.IP
}

func parseIPv4(b []byte) (*IPv4Hdr, int, error) {
	if len(b) < 20 {
		return nil, 0, fmt.Errorf("short IPv4 header")
	}

	vihl := b[0]

	ihl := vihl & 0x0F

	hdrLen := int(ihl) * 4

	if hdrLen < 20 || len(b) < hdrLen {
		return nil, 0, fmt.Errorf("bad IPv4 header length")
	}

	return &IPv4Hdr{
		IHL:      ihl,
		Protocol: b[9],
		SrcIP:    net.IPv4(b[12], b[13], b[14], b[15]),
		DstIP:    net.IPv4(b[16], b[17], b[18], b[19]),
	}, hdrLen, nil
}

// TCP
type TCPHdr struct {
	SrcPort uint16
	DstPort uint16
	Seq     uint32
	Ack     uint32
	Flags   uint8
}

func parseTCP(b []byte) (*TCPHdr, int, error) {
	if len(b) < 20 {
		return nil, 0, fmt.Errorf("short TCP header")
	}

	dataOff := (b[12] >> 4) & 0x0F
	hdrLen := int(dataOff) * 4

	if hdrLen < 20 || len(b) < hdrLen {
		return nil, 0, fmt.Errorf("bad TCP header length")
	}

	return &TCPHdr{
		SrcPort: binary.BigEndian.Uint16(b[0:2]),
		DstPort: binary.BigEndian.Uint16(b[2:4]),
		Seq:     binary.BigEndian.Uint32(b[4:8]),
		Ack:     binary.BigEndian.Uint32(b[8:12]),
		Flags:   b[13],
	}, hdrLen, nil
}

// BPF + Fanout
// TODO: double-tag (QinQ) variant or an auxdata-aware approach
func attachBPF(fd int, localIP net.IP, sportLo, sportHi uint16) error {
	ip4 := localIP.To4()
	if ip4 == nil {
		return fmt.Errorf("attachBPF: non-IPv4 local IP")
	}

	ipK := uint32(ip4[0])<<24 | uint32(ip4[1])<<16 | uint32(ip4[2])<<8 | uint32(ip4[3])
	lo := uint32(sportLo)
	hi := uint32(sportHi)

	// Instruction indices shown at left for sanity.
	prog := []unix.SockFilter{
		//  0: EtherType @ [12]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 12},
		//  1: vlan? (0x8100) -> jump to VLAN block @16
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x8100, Jt: 14, Jf: 0},
		//  2: vlan? (0x88a8) -> VLAN block @16
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x88A8, Jt: 13, Jf: 0},
		//  3: vlan? (0x9100) -> VLAN block @16
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x9100, Jt: 12, Jf: 0},

		// Non-VLAN path (IPv4 at L2+14)
		//  4: if EtherType != IPv4 -> drop
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 1, Jf: 0},
		//  5: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
		//  6: proto @ [23]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 23},
		//  7: if proto != TCP -> drop (jf=7 to instr 15)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 7},
		//  8: dst ip @ [30]
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 30},
		//  9: if dst != local -> drop (jf=5 to 15)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipK, Jt: 0, Jf: 5},
		// 10: X = 4*(IHL) @ [14]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 14},
		// 11: tcp dport @ [16+X]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 16},
		// 12: if dport < lo -> drop (jf=2 to 15)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 13: if dport > hi -> drop (jt=1 to 15)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 14: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 15: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// VLAN path (single tag; IPv4 at L2+18)
		// 16: inner EtherType @ [16]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 16},
		// 17: if inner EtherType != IPv4 -> drop (jf=9 to 27)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 0, Jf: 9},
		// 18: proto @ [27]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 27},
		// 19: if proto != TCP -> drop (jf=7 to 27)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 7},
		// 20: dst ip @ [34]
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 34},
		// 21: if dst != local -> drop (jf=5 to 27)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipK, Jt: 0, Jf: 5},
		// 22: X = 4*(IHL) @ [18]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 18},
		// 23: tcp dport @ [20+X]  (18 + 2 + X)
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 20},
		// 24: if dport < lo -> drop (jf=2 to 27)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 25: if dport > hi -> drop (jt=1 to 27)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 26: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 27: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
	}

	fprog := unix.SockFprog{Len: uint16(len(prog)), Filter: &prog[0]}

	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &fprog)
}

func enableFanout(fd int, groupID int) error {
	val := ((unix.PACKET_FANOUT_HASH | unix.PACKET_FANOUT_FLAG_DEFRAG) << 16) | (groupID & 0xFFFF)

	return unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_FANOUT, val)
}

// AF_PACKET Open/Bind

func openSnifferOnInterface(iFace string) (int, error) {
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return 0, fmt.Errorf("AF_PACKET socket: %w", err)
	}

	ifi, err := net.InterfaceByName(iFace)
	if err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("iFace %s: %w", iFace, err)
	}

	sll := &unix.SockaddrLinklayer{Protocol: htons(unix.ETH_P_ALL), Ifindex: ifi.Index}
	if err := unix.Bind(fd, sll); err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("bind %s: %w", iFace, err)
	}

	return fd, nil
}

// VLAN-aware L2/L3 parsing + cBPF

func ethernetL3(b []byte) (eth uint16, l3off int, err error) {
	if len(b) < 14 {
		return 0, 0, fmt.Errorf("short ethernet")
	}

	off := 12
	eth = binary.BigEndian.Uint16(b[off : off+2])
	l3off = 14

	// Peel up to two tags (802.1Q / QinQ / 0x9100)
	for i := 0; i < 2; i++ {
		if eth == etherTypeVLAN || eth == etherTypeQinQ || eth == etherType9100 {
			if len(b) < l3off+4 {
				return 0, 0, fmt.Errorf("short vlan header")
			}

			// skip TCI (2 bytes) and read inner ethertype
			eth = binary.BigEndian.Uint16(b[l3off+2 : l3off+4])
			l3off += 4
		} else {
			break
		}
	}

	return eth, l3off, nil
}

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
		uintptr(unsafe.Sizeof(req)),
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

func (s *SYNScanner) runRingReader(ctx context.Context, r *ringBuf) {
	pfd := []unix.PollFd{{Fd: int32(r.fd), Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLNVAL}}
	cur := uint32(0)

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
			if blk == nil || len(blk) < int(h1_first_pkt_off+4) {
				break
			}

			if loadU32(blk, h1_status_off)&tpStatusUser == 0 {
				break // no more ready blocks
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

					if int(pkt_next_off+4) > len(ph) ||
						int(pkt_snaplen_off+4) > len(ph) ||
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
			drained = true
		}

		if drained {
			continue // see if more blocks are ready without poll
		}

		// Nothing ready; block in poll
		_, err := unix.Poll(pfd, int(defaultRetireTovMs)) // align with retire tov
		if err != nil {
			// EINTR and EAGAIN are fine; anything else, exit this reader
			if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
				continue
			}

			return
		}

		// Check for socket errors after successful poll
		if pfd[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			// Socket is in error state, exit this reader
			return
		}
	}
}

// NewSYNScanner creates a new SYN scanner (with TPACKETv3 ring readers)
func NewSYNScanner(timeout time.Duration, concurrency int, log logger.Logger) (*SYNScanner, error) {
	log.Info().Msg("DEBUG: Starting SYN scanner initialization")

	if timeout == 0 {
		timeout = 1 * time.Second // SYN scans can be faster
	}

	if concurrency == 0 {
		concurrency = 256 // Reasonable default to avoid port exhaustion
	}

	log.Info().Msg("DEBUG: Creating raw socket for sending")

	// Create raw socket for sending packets with custom IP headers
	sendSocket, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		return nil, fmt.Errorf("cannot create raw send socket (requires root): %w", err)
	}

	log.Info().Int("socket", sendSocket).Msg("DEBUG: Raw socket created successfully")
	log.Info().Msg("DEBUG: Setting IP_HDRINCL socket option")

	if err = syscall.SetsockoptInt(sendSocket, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("cannot set IP_HDRINCL (requires root): %w", err)
	}

	log.Info().Msg("DEBUG: IP_HDRINCL set successfully")
	log.Info().Msg("DEBUG: Getting local IP and interface")

	// Find a local IP and interface to use
	sourceIP, iface, err := getLocalIPAndInterface()
	if err != nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("failed to get local IP and interface: %w", err)
	}

	log.Info().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("DEBUG: Local IP and interface found")

	sourceIP = sourceIP.To4()
	if sourceIP == nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("non-IPv4 source IP")
	}

	log.Info().Msg("DEBUG: Setting up ring buffers")

	// Build NumCPU ring readers with BPF + FANOUT
	fanoutGroup := (os.Getpid() * 131) & 0xFFFF

	n := runtime.NumCPU()
	log.Info().Int("numCPU", n).Int("fanoutGroup", fanoutGroup).Msg("DEBUG: Ring setup parameters")

	rings := make([]*ringBuf, 0, n)

	for i := 0; i < n; i++ {
		log.Info().Int("ringIndex", i).Msg("DEBUG: Creating ring buffer")
		log.Info().Str("interface", iface).Msg("DEBUG: Opening sniffer on interface")

		fd, err := openSnifferOnInterface(iface)
		if err != nil {
			log.Error().Err(err).Msg("DEBUG: Failed to open sniffer on interface")

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("openSnifferOnInterface failed: %w", err)
		}

		log.Info().Int("fd", fd).Msg("DEBUG: Sniffer opened successfully")
		log.Info().Msg("DEBUG: Attaching BPF filter")

		if err := attachBPF(fd, sourceIP, ephemeralPortStart, ephemeralPortEnd); err != nil {
			log.Error().Err(err).Msg("DEBUG: Failed to attach BPF filter")

			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("BPF filter attachment failed: %w", err)
		}

		log.Info().Msg("DEBUG: BPF filter attached successfully")

		log.Info().Int("fanoutGroup", fanoutGroup).Msg("DEBUG: Enabling packet fanout")
		if err := enableFanout(fd, fanoutGroup); err != nil {
			log.Error().Err(err).Msg("DEBUG: Failed to enable packet fanout")
			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("enableFanout failed: %w", err)
		}

		log.Info().Msg("DEBUG: Packet fanout enabled successfully")
		log.Info().Uint32("blockSize", defaultBlockSize).Uint32("blockCount", defaultBlockCount).Uint32("frameSize", defaultFrameSize).Uint32("retireMs", defaultRetireTovMs).Msg("DEBUG: Setting up TPACKET_V3")

		r, err := setupTPacketV3(fd, defaultBlockSize, defaultBlockCount, defaultFrameSize, defaultRetireTovMs)
		if err != nil {
			log.Error().Err(err).Msg("DEBUG: Failed to setup TPACKET_V3")
			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("setupTPacketV3 failed: %w", err)
		}

		log.Info().Msg("DEBUG: TPACKET_V3 setup successfully")

		rings = append(rings, r)
	}

	log.Info().Int("ringCount", len(rings)).Msg("DEBUG: All ring buffers created successfully")

	return &SYNScanner{
		timeout:        timeout,
		concurrency:    concurrency,
		logger:         log,
		sendSocket:     sendSocket,
		rings:          rings,
		sourceIP:       sourceIP,
		iface:          iface,
		fanoutGroup:    fanoutGroup,
		portAlloc:      NewPortAllocator(ephemeralPortStart, ephemeralPortEnd),
		retryAttempts:  2,
		retryMinJitter: 20 * time.Millisecond,
		retryMaxJitter: 40 * time.Millisecond,
		// Initialize maps to prevent nil pointer dereference
		portTargetMap: make(map[uint16]string),
		targetIP:      make(map[string][4]byte),
		results:       make(map[string]models.Result),
	}, nil
}

func (s *SYNScanner) hasFinalResult(targetKey string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	r, ok := s.results[targetKey]

	return ok && (r.Available || r.Error != nil)
}

func (s *SYNScanner) jitterSleep() {
	span := s.retryMaxJitter - s.retryMinJitter
	if span <= 0 {
		time.Sleep(s.retryMinJitter)
		return
	}

	d := s.retryMinJitter + time.Duration(rand.Int63n(int64(span)))

	time.Sleep(d)
}

// Scan performs SYN scanning on the given targets
func (s *SYNScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterTCPTargets(targets)
	resultCh := make(chan models.Result, len(tcpTargets))

	if len(tcpTargets) == 0 {
		close(resultCh)
		return resultCh, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)

	// Initialize state for the new scan and atomically set up the scan
	s.mu.Lock()
	if s.cancel != nil {
		s.mu.Unlock()
		return nil, fmt.Errorf("scan already running")
	}

	s.cancel = cancel
	s.readersWG.Add(1) // MUST come before Stop() can see non-nil cancel

	s.results = make(map[string]models.Result, len(tcpTargets))
	s.portTargetMap = make(map[uint16]string, len(tcpTargets))
	s.targetIP = make(map[string][4]byte, len(tcpTargets))

	s.mu.Unlock()

	// Stream results immediately to resultCh (deduped so the final pass won't resend)
	emitted := make(map[string]struct{}, len(tcpTargets))

	var emittedMu sync.Mutex

	// Dedicated emitter to avoid per-result goroutines.
	// Buffered to the exact number of TCP targets; the callback enqueues at most once per target.
	emitCh := make(chan models.Result, len(tcpTargets))
	stopEmit := make(chan struct{})
	emitterDone := make(chan struct{})

	// Single goroutine drains emitCh -> resultCh, then closes resultCh after a stop signal + drain.
	go func() {
		defer close(emitterDone)
		for {
			select {
			case r := <-emitCh:
				// Forward to consumer
				resultCh <- r

				// Tee to user callback here (not in ring threads)
				if cbAny := s.userCallback.Load(); cbAny != nil {
					if cb, _ := cbAny.(func(models.Result)); cb != nil {
						cb(r)
					}
				}
			case <-stopEmit:
				// Drain any residual items and close the results channel exactly once.
				for {
					select {
					case r := <-emitCh:
						resultCh <- r

						if cbAny := s.userCallback.Load(); cbAny != nil {
							if cb, _ := cbAny.(func(models.Result)); cb != nil {
								cb(r)
							}
						}
					default:
						close(resultCh)

						return
					}
				}
			}
		}
	}()

	s.mu.Lock()
	s.resultCallback = func(r models.Result) {
		key := fmt.Sprintf("%s:%d", r.Target.Host, r.Target.Port)

		emittedMu.Lock()
		if _, seen := emitted[key]; seen {
			emittedMu.Unlock()
			return
		}

		emitted[key] = struct{}{}
		emittedMu.Unlock()

		// Non-blocking in practice: emitCh capacity == len(tcpTargets) and we enqueue ≤1 per target.
		emitCh <- r
	}

	s.mu.Unlock()

	// Start ring readers (one goroutine per ring) — manage with scanner-level WG

	go func() {
		defer s.readersWG.Done()
		s.listenForReplies(scanCtx)
	}()

	// Start worker pool to send SYN packets
	workCh := make(chan models.Target, s.concurrency)

	var senderWg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		senderWg.Add(1)

		go func() {
			defer senderWg.Done()
			s.worker(scanCtx, workCh)
		}()
	}

	// Feed targets to workers
	go func() {
		for _, t := range tcpTargets {
			select {
			case workCh <- t:
			case <-scanCtx.Done():
				return
			}
		}

		close(workCh)
	}()

	// Aggregate
	go func() {
		senderWg.Wait()

		// Shorter grace for late replies
		grace := s.timeout / 4
		if grace > 200*time.Millisecond {
			grace = 200 * time.Millisecond
		}

		time.Sleep(grace)

		cancel()
		s.readersWG.Wait()

		// Fallback: emit anything not yet streamed (via emitter so user callback is tee'd)
		s.mu.Lock()

		for _, t := range tcpTargets {
			key := fmt.Sprintf("%s:%d", t.Host, t.Port)
			emittedMu.Lock()

			if _, seen := emitted[key]; seen {
				emittedMu.Unlock()
				continue
			}

			emitted[key] = struct{}{}
			emittedMu.Unlock()

			r, ok := s.results[key]
			if !ok {
				r = models.Result{
					Target:    t,
					Available: false,
					Error:     fmt.Errorf("scan timed out"),
					FirstSeen: time.Now(),
					LastSeen:  time.Now(),
				}
			} else if !r.Available && r.Error == nil {
				r.Error = fmt.Errorf("scan timed out")
			}

			// Release lock while enqueueing; emitter handles backpressure and user callback tee.
			s.mu.Unlock()
			emitCh <- r
			s.mu.Lock()
		}

		// Stop future callback enqueues and finish the emitter cleanly.
		s.resultCallback = nil
		s.mu.Unlock()

		close(stopEmit) // signal emitter to drain and close resultCh
		<-emitterDone   // wait for emitter to finish

		s.mu.Lock()
		if s.cancel != nil {
			s.cancel = nil
		}

		s.mu.Unlock()
	}()

	return resultCh, nil
}

// worker sends SYN packets to targets from the work channel
func (s *SYNScanner) worker(ctx context.Context, workCh <-chan models.Target) {
	for {
		select {
		case target, ok := <-workCh:
			if !ok {
				return
			}

			key := fmt.Sprintf("%s:%d", target.Host, target.Port)

			for attempt := 0; attempt < s.retryAttempts; attempt++ {
				s.sendSyn(ctx, target)

				if attempt+1 < s.retryAttempts {
					s.jitterSleep()

					if s.hasFinalResult(key) {
						break
					}
				}
			}
		case <-ctx.Done():
			return
		}
	}
}

// listenForReplies pumps all ring readers (ctx-driven)
func (s *SYNScanner) listenForReplies(ctx context.Context) {
	var wg sync.WaitGroup

	for _, r := range s.rings {
		wg.Add(1)

		go func(rr *ringBuf) {
			defer wg.Done()
			s.runRingReader(ctx, rr)
		}(r)
	}

	<-ctx.Done()
	wg.Wait()
}

// processEthernetFrame parses an Ethernet frame and extracts TCP response information.
func (s *SYNScanner) processEthernetFrame(frame []byte) {
	ethType, l3off, err := ethernetL3(frame)
	if err != nil || ethType != etherTypeIPv4 {
		return
	}

	if len(frame) < l3off+20 {
		return
	}

	ip, ipLen, err := parseIPv4(frame[l3off:])
	if err != nil || ip.Protocol != syscall.IPPROTO_TCP {
		return
	}

	if len(frame) < l3off+ipLen+20 {
		return
	}

	tcp, _, err := parseTCP(frame[l3off+ipLen:])
	if err != nil {
		return
	}

	// Precompute inexpensive bits *outside* the lock.
	now := time.Now()

	src4 := ip.SrcIP.To4()
	if src4 == nil {
		return
	}

	// We minimize time under s.mu. All map mutation stays inside; any potentially
	// blocking work (callback -> channel send) happens after we unlock.
	var (
		emit      bool
		toEmit    models.Result
		cb        func(models.Result)
		targetKey string
		toFree    []uint16
	)

	s.mu.Lock()
	targetKey, ok := s.portTargetMap[tcp.DstPort]
	if !ok {
		s.mu.Unlock()
		return
	}

	want := s.targetIP[targetKey]
	if src4[0] != want[0] || src4[1] != want[1] || src4[2] != want[2] || src4[3] != want[3] {
		s.mu.Unlock()
		return
	}

	result := s.results[targetKey]
	if result.Available || result.Error != nil {
		s.mu.Unlock()
		return
	}

	// Decide if this packet makes the port state "definitive".
	// We keep this simple and conservative: any SYN/ACK or RST is definitive.
	if tcp.Flags&(synFlag|ackFlag) == (synFlag | ackFlag) {
		result.Available = true
		result.Error = nil
		emit = true
	} else if tcp.Flags&rstFlag != 0 {
		result.Available = false
		result.Error = fmt.Errorf("port closed (RST)")
		emit = true
	} else {
		s.mu.Unlock()
		return
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = now

	// Persist the updated result.
	s.results[targetKey] = result

	// Remove all src-port mappings for this target and free them after unlock.
	toFree = append(toFree, tcp.DstPort)
	delete(s.portTargetMap, tcp.DstPort)

	for sp, key := range s.portTargetMap {
		if key == targetKey {
			delete(s.portTargetMap, sp)
			toFree = append(toFree, sp)
		}
	}

	// If we want to emit, capture the callback and a copy of the result *under the lock*,
	// then invoke it after unlocking to avoid holding s.mu during a possibly blocking send.
	if emit && s.resultCallback != nil {
		toEmit = result
		cb = s.resultCallback
	}

	s.mu.Unlock()

	// Release ports outside the lock
	for _, sp := range toFree {
		s.portAlloc.Release(sp)
	}

	if emit && cb != nil {
		cb(toEmit)
	}
}

// handleLoopbackTarget handles TCP scanning for loopback addresses using connect()
func (s *SYNScanner) handleLoopbackTarget(ctx context.Context, target models.Target) {
	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	result := models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Use simple connect() for loopback targets
	d := net.Dialer{Timeout: s.timeout}
	addr := net.JoinHostPort(target.Host, fmt.Sprintf("%d", target.Port))

	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		result.Available = false
		result.Error = err
	} else {
		result.Available = true
		conn.Close()
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = time.Now()

	// Store & emit without holding s.mu inside the callback.
	s.emitResult(targetKey, result)
}

// sendSyn crafts and sends a single SYN packet to the target.
func (s *SYNScanner) sendSyn(ctx context.Context, target models.Target) {
	destIP := net.ParseIP(target.Host)
	if destIP == nil || destIP.To4() == nil {
		s.logger.Warn().Str("host", target.Host).Msg("Invalid/Non-IPv4 target host")
		return
	}

	destIP = destIP.To4()

	// Special case for loopback targets - use simple connect() check
	if destIP.IsLoopback() {
		s.handleLoopbackTarget(ctx, target)
		return
	}

	// Reserve a unique source port
	srcPort, err := s.portAlloc.Reserve(ctx)
	if err != nil {
		s.logger.Debug().Err(err).Str("host", target.Host).Msg("No source port available")
		return
	}

	// Ensure cleanup on any early return
	release := func() {
		s.mu.Lock()
		delete(s.portTargetMap, srcPort)
		s.mu.Unlock()

		s.portAlloc.Release(srcPort)
	}

	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	ip4b := destIP.To4()

	var want [4]byte

	copy(want[:], ip4b)

	s.mu.Lock()
	// Defensive check to ensure maps are initialized
	if s.portTargetMap == nil {
		s.portTargetMap = make(map[uint16]string)
	}

	if s.targetIP == nil {
		s.targetIP = make(map[string][4]byte)
	}

	if s.results == nil {
		s.results = make(map[string]models.Result)
	}

	s.portTargetMap[srcPort] = targetKey
	s.targetIP[targetKey] = want
	if existing, ok := s.results[targetKey]; ok && !existing.FirstSeen.IsZero() {
		existing.LastSeen = time.Now()
		s.results[targetKey] = existing
	} else {
		s.results[targetKey] = models.Result{
			Target:    target,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}
	}

	s.mu.Unlock()

	// Ensure we don't hold the source port forever if the target never replies.
	// Free the mapping after timeout + grace to still accept late replies.
	grace := s.timeout / 4
	if grace > 200*time.Millisecond {
		grace = 200 * time.Millisecond
	}

	time.AfterFunc(s.timeout+grace, func() {
		s.mu.Lock()

		if key, ok := s.portTargetMap[srcPort]; ok && key == targetKey {
			delete(s.portTargetMap, srcPort)

			// Do not modify s.results here.
			// End-of-scan fallback will set timeout if still undecided.
			s.mu.Unlock()
			s.portAlloc.Release(srcPort)

			return
		}
		s.mu.Unlock()
	})

	if target.Port <= 0 || target.Port > maxPortNumber {
		s.logger.Warn().Int("port", target.Port).Msg("Invalid target port")
		release()

		return
	}

	packet := buildSynPacket(s.sourceIP, destIP, srcPort, uint16(target.Port)) //nolint:gosec
	addr := syscall.SockaddrInet4{Port: target.Port}

	copy(addr.Addr[:], destIP)

	if err := syscall.Sendto(s.sendSocket, packet, 0, &addr); err != nil {
		s.logger.Debug().Err(err).Str("host", target.Host).Msg("Failed to send SYN packet")
		release()

		return
	}
}

// SetResultCallback sets a callback function that will be called immediately when a result becomes available
func (s *SYNScanner) SetResultCallback(callback func(models.Result)) {
	// Allow changing user callback at any time without touching the internal one.
	s.userCallback.Store(callback)
}

// emitResult stores the result and, if definitive, calls the callback *after* releasing s.mu.
// Callers MUST NOT hold s.mu when invoking this function.
func (s *SYNScanner) emitResult(targetKey string, result models.Result) {
	var cb func(models.Result)

	s.mu.Lock()
	if s.results == nil {
		s.results = make(map[string]models.Result)
	}

	s.results[targetKey] = result
	if s.resultCallback != nil && (result.Available || result.Error != nil) {
		cb = s.resultCallback
	}

	s.mu.Unlock()
	if cb != nil {
		cb(result)
	}
}

// Stop gracefully stops the scanner
func (s *SYNScanner) Stop(_ context.Context) error {
	// Grab and clear the cancel func WITHOUT holding the lock while we wait
	var cancel context.CancelFunc

	s.mu.Lock()
	cancel = s.cancel
	s.cancel = nil
	s.mu.Unlock()

	if cancel != nil {
		cancel()
	}

	// IMPORTANT: wait for the listener (and thus all ring readers) to exit
	// Do NOT hold s.mu here (processEthernetFrame uses it).
	s.readersWG.Wait()

	// Now it is safe to unmap/close the ring and socket resources.
	s.mu.Lock()

	toRelease := make([]uint16, 0, len(s.portTargetMap))

	for src := range s.portTargetMap {
		toRelease = append(toRelease, src)
	}

	s.portTargetMap = nil

	s.mu.Unlock()

	for _, src := range toRelease {
		s.portAlloc.Release(src)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	var err error

	for _, r := range s.rings {
		if r.mem != nil {
			if e := unix.Munmap(r.mem); e != nil && err == nil {
				err = e
			}

			r.mem = nil
		}

		if r.fd != 0 {
			if e := unix.Close(r.fd); e != nil && err == nil {
				err = e
			}

			r.fd = 0
		}
	}

	s.rings = nil

	if s.sendSocket != 0 {
		if e := syscall.Close(s.sendSocket); e != nil && err == nil {
			err = e
		}

		s.sendSocket = 0
	}

	return err
}

// Packet Crafting and Utility Functions

func buildSynPacket(srcIP, destIP net.IP, srcPort, destPort uint16) []byte {
	return buildIPv4TCPSYN(srcIP, destIP, srcPort, destPort, uint16(rand.Intn(65535)))
}

// buildIPv4TCPSYN creates a complete IPv4+TCP SYN packet with proper checksums
func buildIPv4TCPSYN(srcIP, dstIP net.IP, srcPort, dstPort uint16, id uint16) []byte {
	// IPv4 header (20 bytes)
	ip := make([]byte, 20)
	ip[0] = 0x45 // version=4, ihl=5
	ip[1] = 0    // TOS

	binary.BigEndian.PutUint16(ip[2:], 40) // total length (20 IP + 20 TCP)
	binary.BigEndian.PutUint16(ip[4:], id) // ID
	binary.BigEndian.PutUint16(ip[6:], 0)  // flags+frag

	ip[8] = 64 // TTL
	ip[9] = syscall.IPPROTO_TCP

	copy(ip[12:16], srcIP.To4())
	copy(ip[16:20], dstIP.To4())

	binary.BigEndian.PutUint16(ip[10:], ChecksumNew(ip))

	// TCP header (20 bytes)
	tcp := make([]byte, 20)

	binary.BigEndian.PutUint16(tcp[0:], srcPort)
	binary.BigEndian.PutUint16(tcp[2:], dstPort)
	binary.BigEndian.PutUint32(tcp[4:], rand.Uint32()) // random Seq
	binary.BigEndian.PutUint32(tcp[8:], 0)             // Ack

	tcp[12] = (5 << 4) // data offset=5
	tcp[13] = 0x02     // SYN

	binary.BigEndian.PutUint16(tcp[14:], defaultTCPWindow)

	tcp[16], tcp[17] = 0, 0 // checksum (to be filled)

	binary.BigEndian.PutUint16(tcp[18:], 0) // Urgent ptr
	binary.BigEndian.PutUint16(tcp[16:], TCPChecksumNew(srcIP, dstIP, tcp, nil))

	return append(ip, tcp...)
}

// Checksum helpers

func ChecksumNew(data []byte) uint16 {
	sum := uint32(0)

	for len(data) > 1 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}

	if len(data) > 0 {
		sum += uint32(data[0]) << 8
	}

	for (sum >> 16) > 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}

	return ^uint16(sum)
}

// TCP checksum with IPv4 pseudo-header
func TCPChecksumNew(src, dst net.IP, tcpHdr, payload []byte) uint16 {
	psh := make([]byte, 12+len(tcpHdr)+len(payload))

	copy(psh[0:4], src.To4())
	copy(psh[4:8], dst.To4())

	psh[8] = 0
	psh[9] = syscall.IPPROTO_TCP

	binary.BigEndian.PutUint16(psh[10:12], uint16(len(tcpHdr)+len(payload)))

	copy(psh[12:], tcpHdr)
	copy(psh[12+len(tcpHdr):], payload)

	return ChecksumNew(psh)
}

func getLocalIPAndInterface() (net.IP, string, error) {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		// Fallback for environments without internet access
		interfaces, err := net.Interfaces()
		if err != nil {
			return nil, "", err
		}

		for _, iface := range interfaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}

			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}

			for _, addr := range addrs {
				if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil {
					return ipnet.IP.To4(), iface.Name, nil
				}
			}
		}

		return nil, "", fmt.Errorf("no suitable local IP address and interface found")
	}

	defer conn.Close()

	localAddr := conn.LocalAddr().(*net.UDPAddr)
	localIP := localAddr.IP.To4()

	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, "", err
	}

	for _, iface := range interfaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.Equal(localIP) {
				return localIP, iface.Name, nil
			}
		}
	}

	return nil, "", fmt.Errorf("could not find interface for local IP %s", localIP)
}

func getLocalIP() (net.IP, error) {
	ip, _, err := getLocalIPAndInterface()

	return ip, err
}

// Host to network short/long byte order conversions
func htons(n uint16) uint16 { return (n << 8) | (n >> 8) }
func ntohs(n uint16) uint16 { return htons(n) }
