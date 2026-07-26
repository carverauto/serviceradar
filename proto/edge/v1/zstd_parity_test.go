/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package edgev1_test

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// TestZstdParityManifest re-derives every verdict in zstd_parity_manifest.txt from
// Go's OWN compression validator and fails if any has drifted.
//
// The manifest is what the Elixir CompressionValidate suite asserts against, so
// this test is the anchor that keeps the cross-language claim honest: if Go's
// behaviour changes, the committed manifest stops matching HERE, rather than
// Elixir silently continuing to mirror a stale expectation.
func TestZstdParityManifest(t *testing.T) {
	rows := readZstdManifest(t)

	if len(rows) < 7 {
		t.Fatalf("expected the full fixture set in the manifest, got %d rows", len(rows))
	}

	distinct := map[string]struct{}{}
	for _, r := range rows {
		distinct[r.verdict] = struct{}{}
	}

	// A manifest whose rows all share one verdict would let the Elixir test pass
	// vacuously.
	if len(distinct) < 3 {
		t.Fatalf("manifest exercises only %d distinct verdicts; it must cover ok + multiple rejections", len(distinct))
	}

	for _, r := range rows {
		payload, err := os.ReadFile(filepath.Join(zstdTestdataDir(t), r.name+".bin"))
		if err != nil {
			t.Fatalf("%s: %v", r.name, err)
		}

		if got := zstdVerdict(payload, r.declared, r.encoded); got != r.verdict {
			t.Errorf("%s: manifest says %q, Go now says %q", r.name, r.verdict, got)
		}
	}
}

// zstdVerdict applies the SAME ordered checks validateCompression applies on its
// ZSTD arm: the declared-size guard (which refuses a decompression bomb before
// decoding) runs first, then the frame validation.
func zstdVerdict(payload []byte, declared, encoded uint32) string {
	u := uint64(declared)
	if u == 0 || u > edgerecord.MaxUncompressedBytes || u > uint64(encoded)*edgerecord.MaxCompressionRatio {
		return "uncompressed_size"
	}

	err := edgerecord.ValidateZstdPayload(payload, declared)

	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, edgerecord.ErrZstdTrailing):
		return "zstd_trailing"
	case errors.Is(err, edgerecord.ErrZstdOutputSize):
		return "zstd_output_size"
	case errors.Is(err, edgerecord.ErrZstdInvalid):
		return "zstd_invalid"
	default:
		return "unknown:" + err.Error()
	}
}

type zstdManifestRow struct {
	name              string
	declared, encoded uint32
	verdict           string
}

func readZstdManifest(t *testing.T) []zstdManifestRow {
	t.Helper()

	f, err := os.Open(filepath.Join(zstdTestdataDir(t), "zstd_parity_manifest.txt"))
	if err != nil {
		t.Fatalf("open manifest: %v", err)
	}
	defer f.Close()

	var rows []zstdManifestRow

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}

		parts := strings.Split(line, "\t")
		if len(parts) != 4 {
			t.Fatalf("malformed manifest row %q", line)
		}

		declared, err := strconv.ParseUint(parts[1], 10, 32)
		if err != nil {
			t.Fatalf("row %q: declared: %v", line, err)
		}

		encoded, err := strconv.ParseUint(parts[2], 10, 32)
		if err != nil {
			t.Fatalf("row %q: encoded: %v", line, err)
		}

		rows = append(rows, zstdManifestRow{
			name:     parts[0],
			declared: uint32(declared),
			encoded:  uint32(encoded),
			verdict:  parts[3],
		})
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("scan manifest: %v", err)
	}

	return rows
}

// zstdTestdataDir resolves testdata under both `go test` (relative) and Bazel
// (runfiles), matching how the other edge fixtures are located.
func zstdTestdataDir(t *testing.T) string {
	t.Helper()

	if dir := os.Getenv("TEST_SRCDIR"); dir != "" {
		candidate := filepath.Join(dir, os.Getenv("TEST_WORKSPACE"), "proto", "edge", "v1", "testdata")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}

	return "testdata"
}
