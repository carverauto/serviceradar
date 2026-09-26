package simkit

import (
	"errors"
	"strconv"
	"strings"
)

// Minter derives stable identities for simulated assets. The same seed,
// namespace, kind and index always produce the same identifiers.
type Minter struct {
	Seed      uint64
	Namespace string
}

// AssetID returns a readable, stable id such as "ap-0007".
func (m Minter) AssetID(kind string, index int) string {
	return kind + "-" + pad(index, 4)
}

// Serial returns a stable 12-character serial number for an asset.
func (m Minter) Serial(kind string, index int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	h := Hash(m.Seed, m.Namespace, "serial", kind, strconv.Itoa(index))
	var b strings.Builder
	b.Grow(12)
	for i := 0; i < 12; i++ {
		b.WriteByte(alphabet[h%uint64(len(alphabet))])
		h /= uint64(len(alphabet))
		if h == 0 {
			h = Hash(m.Seed, m.Namespace, "serial-ext", kind, strconv.Itoa(index), strconv.Itoa(i))
		}
	}
	return b.String()
}

// MAC returns a stable MAC address. A zero OUI yields a locally administered
// unicast address; otherwise the given vendor OUI is used.
func (m Minter) MAC(kind string, index int, oui [3]byte) string {
	h := Hash(m.Seed, m.Namespace, "mac", kind, strconv.Itoa(index))
	b := [6]byte{oui[0], oui[1], oui[2], byte(h), byte(h >> 8), byte(h >> 16)}
	if oui == [3]byte{} {
		b[0] = 0x02
		b[1] = byte(h >> 24)
		b[2] = byte(h >> 32)
	}
	const hex = "0123456789abcdef"
	out := make([]byte, 0, 17)
	for i, v := range b {
		if i > 0 {
			out = append(out, ':')
		}
		out = append(out, hex[v>>4], hex[v&0x0f])
	}
	return string(out)
}

// ErrAddressSpace is returned when an offset does not fit in a prefix.
var ErrAddressSpace = errors.New("simkit: offset outside prefix host range")

// IPv4 returns the host at the given offset (starting at 1) inside an IPv4
// prefix written as "a.b.c.d/len". Network and broadcast addresses are never
// returned.
func IPv4(prefix string, offset uint32) (string, error) {
	base, bits, err := parsePrefix4(prefix)
	if err != nil {
		return "", err
	}
	hostBits := 32 - bits
	if hostBits < 2 {
		return "", ErrAddressSpace
	}
	size := uint64(1) << hostBits
	if offset == 0 || uint64(offset) >= size-1 {
		return "", ErrAddressSpace
	}
	v := (base &^ uint32(size-1)) + offset
	return strconv.Itoa(int(v>>24)) + "." + strconv.Itoa(int(v>>16&0xff)) + "." +
		strconv.Itoa(int(v>>8&0xff)) + "." + strconv.Itoa(int(v&0xff)), nil
}

func parsePrefix4(s string) (uint32, int, error) {
	addr, lenPart, ok := strings.Cut(s, "/")
	if !ok {
		return 0, 0, errors.New("simkit: prefix needs /len")
	}
	bits, err := strconv.Atoi(lenPart)
	if err != nil || bits < 0 || bits > 32 {
		return 0, 0, errors.New("simkit: bad prefix length")
	}
	octets := strings.Split(addr, ".")
	if len(octets) != 4 {
		return 0, 0, errors.New("simkit: bad IPv4 address")
	}
	var v uint32
	for _, o := range octets {
		n, err := strconv.Atoi(o)
		if err != nil || n < 0 || n > 255 {
			return 0, 0, errors.New("simkit: bad IPv4 octet")
		}
		v = v<<8 | uint32(n)
	}
	return v, bits, nil
}

func pad(v, width int) string {
	s := strconv.Itoa(v)
	for len(s) < width {
		s = "0" + s
	}
	return s
}
