// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	"google.golang.org/protobuf/proto"
)

func recoveryPhysicalBytes(root string) (uint64, error) {
	var total uint64
	err := filepath.WalkDir(root, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Blocks < 0 {
			return fmt.Errorf("filesystem does not expose allocated blocks")
		}
		total += uint64(stat.Blocks) * 512
		return nil
	})
	return total, err
}

func largeRecoveryInput(t *testing.T) (AttributedAppend, LaneKey, Identity) {
	t.Helper()
	return attributionAppendMutated(t, "metrics", func(r *edgev1.EdgeRecordV1) {
		var batch metricpb.MetricBatch
		if err := proto.Unmarshal(r.Payload, &batch); err != nil {
			t.Fatal(err)
		}
		batch.Metrics[0].Points = []*metricpb.MetricPoint{{RawValue: strings.Repeat("7", 32<<10), RawValueType: metricpb.MetricValueType_METRIC_VALUE_TYPE_STRING}}
		payload, err := proto.Marshal(&batch)
		if err != nil {
			t.Fatal(err)
		}
		r.Payload = payload
		hash := sha256.Sum256(payload)
		r.PayloadSha256 = hash[:]
		r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
		r.ProjectedWriteBytes = uint64(len(payload))
		r.ProductionCapability.GetProduction().MaxProjectedWriteBytes = r.ProjectedWriteBytes
	})
}

func freezeDamagedGeneration(t *testing.T, lanes *LaneSet, source *Generation, allocator *Allocator, input AttributedAppend, dir string, id []byte) *recoveryFixture {
	t.Helper()
	destination, grant, err := lanes.BeginRecoveryDestination(source, id, 0, allocator)
	if err != nil {
		t.Fatal("reserve next bounded source", err)
	}
	controlKey := LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	control, err := lanes.CreateRecoveryControlDestination(controlKey, id, 0, grant)
	if err != nil {
		t.Fatal(err)
	}
	operation, err := BeginRecoveryOperation(dir, source, destination, grant, 1800000000000000000, "synthetic damaged record")
	if err != nil {
		t.Fatal(err)
	}
	plan := operation.plan
	return &recoveryFixture{dir: dir, lanes: lanes, source: source, destination: destination, control: control, allocator: allocator, grant: grant, operation: operation, plan: plan, input: input, identity: source.id.Identity}
}

func TestBoundedRecoveryMakesPhysicalProgressAtFullOrdinaryCeiling(t *testing.T) {
	runBoundedRecoveryAtFloor(t, false)
}
func TestRecoveryRetainsAllRejectedBytesAndReportsCapacity(t *testing.T) {
	runBoundedRecoveryAtFloor(t, true)
}
func runBoundedRecoveryAtFloor(t *testing.T, allRejected bool) {
	root := t.TempDir()
	input, key, identity := largeRecoveryInput(t)
	var physicalLimit uint64
	configuration := AllocatorConfig{Capacity: 128 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: DefaultRecoveryFootprint(), FreeBytes: func() (uint64, error) {
		if physicalLimit == 0 {
			return 1 << 30, nil
		}
		used, err := recoveryPhysicalBytes(root)
		if err != nil || used > physicalLimit {
			return 0, err
		}
		return physicalLimit - used, nil
	}}
	allocator, err := NewAllocator(configuration)
	if err != nil {
		t.Fatal(err)
	}
	lanes := openAttributedLanes(t, filepath.Join(root, "lanes"), identity, allocator, nil)
	t.Cleanup(func() {
		if err := lanes.Close(); err != nil {
			t.Error(err)
		}
	})
	// This exceeds two maximum operation intervals. Physical byte bounds must
	// rotate it into independently recoverable generations, even for one key.
	for i := 0; i < 2049; i++ {
		_, err = lanes.AppendAttributed(key, identity, input)
		if errors.Is(err, ErrRotationRequired) {
			if _, err = lanes.Rotate(key); err != nil {
				t.Fatal(err)
			}
			_, err = lanes.AppendAttributed(key, identity, input)
		}
		if err != nil {
			t.Fatal("populate bounded source", i, err)
		}
	}
	active, _ := lanes.OpenGeneration(key)
	active.spool.beforeBarrier = func(at barrier) error {
		if at == barrierRecord {
			return syscall.EIO
		}
		return nil
	}
	if _, err = lanes.AppendAttributed(key, identity, input); !errors.Is(err, syscall.EIO) {
		t.Fatal("active source crash not reached", err)
	}
	if err = lanes.Close(); err != nil {
		t.Fatal(err)
	}
	allocator, err = NewAllocator(configuration)
	if err != nil {
		t.Fatal(err)
	}
	lanes = openAttributedLanes(t, filepath.Join(root, "lanes"), identity, allocator, nil)
	active, _ = lanes.OpenGeneration(key)
	if active.Closed() {
		t.Fatal("fixture preclosed ambiguous source")
	}
	var sources []*Generation
	var after uint64
	for {
		page := lanes.GenerationsPage(key, after, 2)
		if len(page) == 0 {
			break
		}
		for _, g := range page {
			after = g.Identity().Ordinal
			if g.NextSequence() > 1 {
				sources = append(sources, g)
			}
		}
	}
	if len(sources) < 3 {
		t.Fatal("large source was not physically bounded", len(sources))
	}
	// Recover the still-active ambiguous generation first at the exact floor.
	sources = append([]*Generation{active}, sources[:len(sources)-1]...)
	for _, source := range sources {
		if source == active {
			continue
		}
		path := source.spool.segmentPath()
		file, err := os.OpenFile(path, os.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		info, err := file.Stat()
		if err != nil {
			t.Fatal(err)
		}
		var last [1]byte
		if _, err = file.ReadAt(last[:], info.Size()-1); err != nil {
			t.Fatal(err)
		}
		last[0] ^= 1
		if _, err = file.WriteAt(last[:], info.Size()-1); err != nil {
			t.Fatal(err)
		}
		if err = file.Sync(); err != nil {
			t.Fatal(err)
		}
		if err = file.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if allRejected {
		terminal := mixedRecoveryTerminal(t, active, input, int(active.NextSequence()-2), true)
		if err = active.ResolveWithEvidence(active.NextSequence()-2, terminal); err != nil {
			t.Fatal(err)
		}
	}
	usage := allocator.Usage()
	filler := filepath.Join(root, "synthetic-ordinary-storage")
	fill := usage.OrdinaryCeiling - usage.OrdinaryUsed
	if err = os.WriteFile(filler, bytes.Repeat([]byte{0x53}, int(fill)), filePerm); err != nil {
		t.Fatal(err)
	}
	allocator.ChargeMeasured(filler, fill)
	initial, err := recoveryPhysicalBytes(root)
	if err != nil {
		t.Fatal(err)
	}
	physicalLimit = initial + usage.Floor
	if err = allocator.admit(filler, 1); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatal("ordinary producer borrowed recovery floor", err)
	}
	previous := initial
	for index, source := range sources {
		t.Run(fmt.Sprintf("generation_%d", index), func(t *testing.T) {
			f := freezeDamagedGeneration(t, lanes, source, allocator, input, filepath.Join(root, fmt.Sprintf("operation-%d", index)), recoveryUUID(byte(90+index)))
			publications := prepareRecoveryPublications(t, f)
			for seq := uint64(1); seq < f.plan.Last; seq++ {
				if _, err := f.operation.Copy(seq); err != nil {
					t.Fatal("copy at physical floor", seq, err)
				}
			}
			if err := f.operation.ReclaimSource(); err == nil {
				t.Fatal("source released before authoritative coverage")
			}
			acknowledgeRecoveryPublications(t, f, publications)
			if _, err := f.operation.SealCoverage(); err != nil {
				t.Fatal(err)
			}
			if err := f.operation.ArchiveTerminalEvidence(); err != nil {
				t.Fatal(err)
			}
			if err := f.operation.ReclaimSource(); err != nil {
				t.Fatal(err)
			}
			if allocator.Usage().ActiveRecoveries != 1 {
				t.Fatal("source transfer dropped original grant")
			}
			terminal := mixedRecoveryTerminal(t, f.destination, input, int(f.plan.Last-1), allRejected)
			if err := f.destination.ResolveWithEvidence(f.plan.Last-1, terminal); err != nil {
				t.Fatal(err)
			}
			if err := f.operation.FinishCleanup(recoveryResolutionEvidence(t, f, nil), []*Generation{f.control}); err != nil {
				t.Fatal("complete at physical floor", err)
			}
			if allocator.Usage().ActiveRecoveries != 0 {
				t.Fatal("completed operation blocks next source")
			}
			measured, err := recoveryPhysicalBytes(root)
			if err != nil {
				t.Fatal(err)
			}
			if allRejected {
				for _, name := range []string{recoveryArchiveFile, "destination.archive"} {
					raw, err := os.ReadFile(filepath.Join(f.dir, name))
					if err != nil || bytes.Count(raw, input.Body) != int(f.plan.Last-1) {
						t.Fatal("mandatory rejected body lost", name, err)
					}
				}
				if allocator.Usage().OrdinaryUsed <= allocator.Usage().OrdinaryCeiling {
					t.Fatal("rejection archives were not retained and charged")
				}
				if err = allocator.admit(filler, 1); !errors.Is(err, ErrAdmissionRefused) {
					t.Fatal("retained evidence capacity was not surfaced", err)
				}
				if _, _, err = lanes.BeginRecoveryDestination(sources[1], recoveryUUID(120), 0, allocator); !errors.Is(err, ErrReserveUnbacked) {
					t.Fatal("next recovery ignored physical retained evidence", err)
				}
				t.Logf("retained rejection archives: ordinary=%d ceiling=%d; physical before=%d after=%d", allocator.Usage().OrdinaryUsed, allocator.Usage().OrdinaryCeiling, previous, measured)
				return
			}
			if measured >= previous {
				t.Fatalf("accepted-copy cleanup did not return physical blocks: before=%d after=%d", previous, measured)
			}
			t.Logf("returned %d allocated bytes; source slots=%d", previous-measured, f.plan.Last)
			previous = measured
		})
		if t.Failed() || allRejected {
			break
		}
	}
	if !t.Failed() && !allRejected && previous >= initial {
		t.Fatal("full-spool recovery made no physical progress")
	}
}
