package fastsum

import (
    "bytes"
    "math/rand"
    "testing"
)

func refChecksum(b []byte) uint16 { // simple reference
    var s uint32
    for i := 0; i+1 < len(b); i += 2 {
        s += uint32(b[i])<<8 | uint32(b[i+1])
    }
    if len(b)%2 == 1 {
        s += uint32(b[len(b)-1]) << 8
    }
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return ^uint16(s)
}

func TestChecksumMatchesRef(t *testing.T) {
    r := rand.New(rand.NewSource(1))
    for n := 0; n < 4096; n++ {
        buf := make([]byte, n)
        r.Read(buf)
        got := Checksum(buf)
        want := refChecksum(buf)
        if got != want {
            t.Fatalf("n=%d got=%#04x want=%#04x", n, got, want)
        }
    }
}

func BenchmarkChecksum_64B(b *testing.B)   { benchN(b, 64) }
func BenchmarkChecksum_256B(b *testing.B)  { benchN(b, 256) }
func BenchmarkChecksum_1024B(b *testing.B) { benchN(b, 1024) }

func benchN(b *testing.B, n int) {
    buf := bytes.Repeat([]byte{0x55, 0xAA}, n/2)
    if len(buf) < n { buf = append(buf, 0x55) }
    b.ReportAllocs()
    b.SetBytes(int64(len(buf)))
    for i := 0; i < b.N; i++ {
        _ = Checksum(buf)
    }
}

