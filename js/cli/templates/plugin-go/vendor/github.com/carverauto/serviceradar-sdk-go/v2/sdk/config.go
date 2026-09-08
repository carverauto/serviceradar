package sdk

import (
	"encoding/json"
)

// GetConfig decodes the host-provided configuration into the supplied struct.
func GetConfig(out any) error {
	data, err := getConfigBytes()

	if err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}

	return json.Unmarshal(data, out)
}

// LoadConfig decodes the host-provided configuration into the supplied struct.
func LoadConfig(out any) error {
	return GetConfig(out)
}

func getConfigBytes() ([]byte, error) {
	sizes := []uint32{16 * 1024, 64 * 1024, 256 * 1024, MaxPayloadBytes}

	for i, size := range sizes {
		buf := make([]byte, size)
		if size == 0 {
			return nil, nil
		}

		res := callHostGetConfig(buf)

		if res == hostErrTooLarge && i < len(sizes)-1 {
			continue
		}

		if res < 0 {
			return nil, hostErr(res, "get_config")
		}
		if res == 0 {
			return nil, nil
		}
		if uint32(res) > size {
			return nil, HostError{Code: hostErrInvalid, Op: "get_config"}
		}

		return buf[:res], nil
	}

	return nil, HostError{Code: hostErrTooLarge, Op: "get_config"}
}
