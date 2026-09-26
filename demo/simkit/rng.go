package simkit

import "strconv"

const (
	fnvOffset = 14695981039346656037
	fnvPrime  = 1099511628211
)

// Hash mixes a seed and any number of key parts into a well-distributed
// uint64. Parts are length-delimited so ("ab","c") and ("a","bc") differ.
func Hash(seed uint64, parts ...string) uint64 {
	h := uint64(fnvOffset) ^ seed
	for _, p := range parts {
		for i := 0; i < len(p); i++ {
			h ^= uint64(p[i])
			h *= fnvPrime
		}
		h ^= uint64(len(p)) + 0x9e
		h *= fnvPrime
	}
	return splitmix(h)
}

// Unit returns a stable value in [0, 1) for the seed and key parts.
func Unit(seed uint64, parts ...string) float64 {
	return float64(Hash(seed, parts...)>>11) / float64(uint64(1)<<53)
}

// Signed returns a stable value in [-1, 1) for the seed and key parts.
func Signed(seed uint64, parts ...string) float64 {
	return Unit(seed, parts...)*2 - 1
}

// Itoa formats an integer key part.
func Itoa(v int64) string { return strconv.FormatInt(v, 10) }

func splitmix(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}
