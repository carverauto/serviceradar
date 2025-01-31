package scan

import (
	"testing"
)

func TestICMPChecksum(t *testing.T) {
	tests := []struct {
		name     string
		data     []byte
		expected uint16
	}{
		{
			name:     "Empty data",
			data:     []byte{},
			expected: 0xFFFF,
		},
		{
			name:     "Simple ICMP header",
			data:     []byte{8, 0, 0, 0, 0, 1, 0, 1},
			expected: 0xF7FD,
		},
		{
			name:     "Odd length data",
			data:     []byte{8, 0, 0, 0, 0, 1, 0, 1, 0},
			expected: 0xF7FD, // Corrected expected value
		},
	}

	scanner := &ICMPScanner{}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := scanner.calculateChecksum(tt.data)
			if result != tt.expected {
				t.Errorf("calculateChecksum() = %#x, want %#x", result, tt.expected)
			}
		})
	}
}
