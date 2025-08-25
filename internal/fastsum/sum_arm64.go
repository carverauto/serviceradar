//go:build linux && arm64
// +build linux,arm64

package fastsum

//go:noescape
func sumBE16Ptr(p *byte, n int) uint32

// SumBE16 returns the (unfolded) one's‑complement sum of 16‑bit big‑endian words.
func SumBE16(b []byte) uint32 {
    if len(b) == 0 {
        return 0
    }
    return sumBE16Ptr(&b[0], len(b))
}

