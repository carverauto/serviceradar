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

package agent

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// writeDrainedFlatSpool lays out what a pre-lane agent's sender leaves after it
// drained and reclaimed its single-lane spool: the segment pointer, the resolved
// watermark, its spool_id, and a reclaimed data directory whose segment is empty.
func writeDrainedFlatSpool(t *testing.T, root string) {
	t.Helper()
	data := ".spool-data-00000000000000000042"
	require.NoError(t, os.MkdirAll(filepath.Join(root, data), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(root, data, "lane.seg"), nil, 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(root, data+".checkpoint"), make([]byte, 88), 0o600))
	require.NoError(t, os.Symlink(data, filepath.Join(root, "lane.seg")))
	require.NoError(t, os.WriteFile(filepath.Join(root, "resolved"), make([]byte, 8), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(root, "spool_id"), make([]byte, 16), 0o600))
}

// A drained flat spool holds no undelivered record, so keeping it only marked the
// agent's edge pipeline not ready forever. It is retired at open; the readiness
// signal (retained legacy bytes) then reports nothing retained.
func TestOpenRecordSpoolRetiresDrainedFlatStorage(t *testing.T) {
	root := t.TempDir()
	writeDrainedFlatSpool(t, root)

	sp, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })

	require.Zero(t, sp.RetainedLegacyBytes())
	inv, retireErr := sp.LegacyRetirement()
	require.NoError(t, retireErr)
	require.Equal(t, []string{".spool-data-00000000000000000042", ".spool-data-00000000000000000042.checkpoint", "lane.seg", "resolved", "spool_id"}, inv.Entries)
	for _, name := range inv.Entries {
		_, statErr := os.Lstat(filepath.Join(root, name))
		require.ErrorIs(t, statErr, os.ErrNotExist, name)
	}
}

// A flat spool that still holds a committed record is never removed: its bytes
// stay retained, charged and reported, so the undelivered record stays visible.
func TestOpenRecordSpoolRetainsFlatStorageWithRecords(t *testing.T) {
	root := t.TempDir()
	flat, err := spool.Open(root)
	require.NoError(t, err)
	_, err = flat.Append(make([]byte, 16), []byte("synthetic undelivered record"))
	require.NoError(t, err)
	require.NoError(t, flat.Close())
	before, err := os.ReadFile(filepath.Join(root, "lane.seg"))
	require.NoError(t, err)

	sp, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })

	require.Positive(t, sp.RetainedLegacyBytes())
	_, retireErr := sp.LegacyRetirement()
	require.ErrorIs(t, retireErr, spool.ErrLegacyFlatNotDrained)
	after, err := os.ReadFile(filepath.Join(root, "lane.seg"))
	require.NoError(t, err)
	require.Equal(t, before, after)
}
