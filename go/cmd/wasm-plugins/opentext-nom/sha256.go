package main

import "math/bits"

// sumSHA256 is a one-shot SHA-256 implementation for snapshot fingerprints.
// TinyGo with Go 1.25 cannot currently execute crypto/sha256's FIPS indicator
// under WASI. This code is not used for authentication or credential handling.
func sumSHA256(data []byte) [32]byte {
	hash := [8]uint32{
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}
	length := len(data)
	for len(data) >= 64 {
		sha256Block(&hash, data[:64])
		data = data[64:]
	}

	var tail [128]byte
	n := copy(tail[:], data)
	tail[n] = 0x80
	blocks := 64
	if n >= 56 {
		blocks = 128
	}
	bitLength := uint64(length) * 8
	for i := 0; i < 8; i++ {
		tail[blocks-1-i] = byte(bitLength >> (8 * i))
	}
	for offset := 0; offset < blocks; offset += 64 {
		sha256Block(&hash, tail[offset:offset+64])
	}

	var sum [32]byte
	for i, value := range hash {
		offset := i * 4
		sum[offset] = byte(value >> 24)
		sum[offset+1] = byte(value >> 16)
		sum[offset+2] = byte(value >> 8)
		sum[offset+3] = byte(value)
	}
	return sum
}

func sha256Block(hash *[8]uint32, block []byte) {
	var words [64]uint32
	for i := 0; i < 16; i++ {
		offset := i * 4
		words[i] = uint32(block[offset])<<24 |
			uint32(block[offset+1])<<16 |
			uint32(block[offset+2])<<8 |
			uint32(block[offset+3])
	}
	for i := 16; i < 64; i++ {
		s0 := bits.RotateLeft32(words[i-15], -7) ^
			bits.RotateLeft32(words[i-15], -18) ^
			(words[i-15] >> 3)
		s1 := bits.RotateLeft32(words[i-2], -17) ^
			bits.RotateLeft32(words[i-2], -19) ^
			(words[i-2] >> 10)
		words[i] = words[i-16] + s0 + words[i-7] + s1
	}

	a, b, c, d := hash[0], hash[1], hash[2], hash[3]
	e, f, g, h := hash[4], hash[5], hash[6], hash[7]
	for i := 0; i < 64; i++ {
		s1 := bits.RotateLeft32(e, -6) ^ bits.RotateLeft32(e, -11) ^ bits.RotateLeft32(e, -25)
		choice := (e & f) ^ (^e & g)
		temporary1 := h + s1 + choice + sha256RoundConstants[i] + words[i]
		s0 := bits.RotateLeft32(a, -2) ^ bits.RotateLeft32(a, -13) ^ bits.RotateLeft32(a, -22)
		majority := (a & b) ^ (a & c) ^ (b & c)
		temporary2 := s0 + majority

		h = g
		g = f
		f = e
		e = d + temporary1
		d = c
		c = b
		b = a
		a = temporary1 + temporary2
	}

	hash[0] += a
	hash[1] += b
	hash[2] += c
	hash[3] += d
	hash[4] += e
	hash[5] += f
	hash[6] += g
	hash[7] += h
}

var sha256RoundConstants = [64]uint32{
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
