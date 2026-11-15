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

package spool

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// writeFlatSpool writes a pre-lane flat spool at root with the real writer:
// accepted records are acknowledged and reclaimed, pending ones stay committed.
func writeFlatSpool(t *testing.T, root string, accepted, pending int) {
	t.Helper()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	for i := 1; i <= accepted+pending; i++ {
		seq, err := s.Append(evid(byte(i)), []byte("synthetic flat record"))
		if err != nil {
			t.Fatal(err)
		}
		if i > accepted {
			continue
		}
		if err := s.ResolveWithEvidence(seq, terminalAck(t, seq, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, seq)); err != nil {
			t.Fatal(err)
		}
		if err := s.ReclaimResolved(); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, legacySpoolIDFile), make([]byte, 16), filePerm); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "lanes"), dirPerm); err != nil {
		t.Fatal(err)
	}
}

func rootNames(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func TestRetireDrainedLegacyFlat(t *testing.T) {
	for _, tc := range []struct {
		name        string
		pending     int
		prepare     func(t *testing.T, root string)
		wantRetired bool
	}{
		{name: "fully drained", wantRetired: true},
		{name: "interrupted after the pointer was removed", wantRetired: true, prepare: func(t *testing.T, root string) {
			t.Helper()
			for _, name := range []string{legacySpoolIDFile, resolvedFile, segmentFile} {
				if err := os.Remove(filepath.Join(root, name)); err != nil {
					t.Fatal(err)
				}
			}
		}},
		{name: "one record awaiting delivery", pending: 1},
		{name: "unrecognized entry beside a drained spool", prepare: func(t *testing.T, root string) {
			t.Helper()
			if err := os.WriteFile(filepath.Join(root, "operator-notes"), []byte("x"), filePerm); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			writeFlatSpool(t, root, 2, tc.pending)
			if tc.prepare != nil {
				tc.prepare(t, root)
			}
			before := rootNames(t, root)

			inv, err := RetireDrainedLegacyFlat(root)

			if !tc.wantRetired {
				if !errors.Is(err, ErrLegacyFlatNotDrained) {
					t.Fatalf("retire = %v, want ErrLegacyFlatNotDrained", err)
				}
				if got := rootNames(t, root); !reflect.DeepEqual(got, before) {
					t.Fatalf("refused retirement changed the root: %v -> %v", before, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("retire drained flat spool: %v", err)
			}
			if !inv.Present() {
				t.Fatal("drained flat spool was not inventoried")
			}
			if got := rootNames(t, root); !reflect.DeepEqual(got, []string{"lanes"}) {
				t.Fatalf("root after retirement = %v, want only the lane format", got)
			}
		})
	}
}
