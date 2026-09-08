package main

import (
	"crypto/sha256"
	"testing"
)

func TestSumSHA256MatchesStandardLibrary(t *testing.T) {
	for _, size := range []int{0, 1, 3, 55, 56, 63, 64, 65, 127, 128, 1000} {
		payload := make([]byte, size)
		for i := range payload {
			payload[i] = byte((i*31 + size) % 251)
		}
		got := sumSHA256(payload)
		want := sha256.Sum256(payload)
		if got != want {
			t.Fatalf("sumSHA256(%d bytes) = %x, want %x", size, got, want)
		}
	}
}
