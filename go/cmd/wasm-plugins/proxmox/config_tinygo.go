//go:build tinygo

package main

import (
	"fmt"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

//go:wasmimport env get_config
func proxmoxHostGetConfig(ptr uint32, size uint32) int32

func loadConfigBytes() ([]byte, error) {
	sizes := []uint32{16 * 1024, 64 * 1024, 256 * 1024, sdk.MaxPayloadBytes}
	for i, size := range sizes {
		buf := make([]byte, size)
		ptr := ptrFromBytes(buf)
		res := proxmoxHostGetConfig(ptr, size)
		if res == -3 && i < len(sizes)-1 {
			continue
		}
		if res < 0 {
			return nil, fmt.Errorf("get_config host error %d", res)
		}
		if res == 0 {
			return nil, nil
		}
		if uint32(res) > size {
			return nil, fmt.Errorf("get_config invalid size %d > %d", res, size)
		}
		return buf[:res], nil
	}

	return nil, fmt.Errorf("get_config payload too large")
}
