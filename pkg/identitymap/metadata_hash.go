package identitymap

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
)

// HashMetadata deterministically hashes metadata maps so CAS operations can reject stale writes.
func HashMetadata(metadata map[string]string) string {
	if len(metadata) == 0 {
		return ""
	}

	keys := make([]string, 0, len(metadata))
	for k := range metadata {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	h := sha256.New()
	for _, k := range keys {
		h.Write([]byte(k))
		h.Write([]byte{0})
		h.Write([]byte(metadata[k]))
		h.Write([]byte{0xff})
	}

	return hex.EncodeToString(h.Sum(nil))
}
