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

package edgerecord

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"slices"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Plan-carried checks (openspec/changes/unify-sweep-results-proto, Decision 12):
// a leased slot runs the checks its push carries, keyed by the check-set digest
// its signed plan header names. This file owns the carrier contract shared by
// core and the agent: the check-set digest grammar, the push-level integrity of
// SweepLeaseV1.check_sets, and the slot-level question of whether one carried
// set is a shape the scanner can run.

// CheckSetDigestVersion is the check-set grammar version a SweepCheckSetV1 names.
const CheckSetDigestVersion = 1

// SweepLeaseCheckSetsVersion is the lease_version of a push that carries slots.
const SweepLeaseCheckSetsVersion = 2

const checkSetDomain = "serviceradar.edge.check_set.v1"

var (
	// ErrSweepLeaseCheckSets refuses the whole push: its carried check sets do
	// not bind its slots. The agent answers with a SweepLeaseAck error.
	ErrSweepLeaseCheckSets = errors.New("edgerecord: sweep lease check sets do not bind the push's slots")
	// ErrSweepCheckSetUnsupported refuses one slot: its carried set is not one the
	// scanner can execute (SWEEP_LEASE_SLOT_REFUSAL_REASON_UNSUPPORTED_PLAN).
	ErrSweepCheckSetUnsupported = errors.New("edgerecord: sweep check set is not executable")
)

// CheckSetDigest is the version 1 check-set digest of checks, in the order given.
// The grammar is ServiceRadar.Edge.HashGrammar.check_set_digest/1; core sorts and
// de-duplicates before hashing, so a canonical list hashes to the same value.
func CheckSetDigest(checks []*edgev1.SweepTestV1) []byte {
	h := sha256.New()
	write := func(v uint64) {
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], v)
		_, _ = h.Write(b[:])
	}
	write(uint64(len(checkSetDomain)))
	_, _ = h.Write([]byte(checkSetDomain))
	write(CheckSetDigestVersion)
	write(uint64(len(checks)))
	for _, check := range checks {
		write(uint64(check.GetMode()))
		write(uint64(check.GetProtocol()))
		write(uint64(check.GetPort()))
	}
	return h.Sum(nil)
}

// SweepLeaseCheckSets verifies that push's carried check sets bind its slots and
// returns them keyed by check_set_sha256. A push with slots is lease_version 2;
// every slot's plan_header.check_set_sha256 resolves to exactly one carried set;
// no carried set is unreferenced; and every set of a known digest_version lists
// its checks in canonical order and digests to its key. A set of an unknown
// digest_version is returned unverified, since its grammar is unknown here:
// SweepCheckSetRun refuses the slots that reference it.
func SweepLeaseCheckSets(push *edgev1.SweepLeaseV1) (map[string]*edgev1.SweepCheckSetV1, error) {
	if len(push.GetSlots()) == 0 {
		if len(push.GetCheckSets()) != 0 {
			return nil, fmt.Errorf("%w: check sets without slots", ErrSweepLeaseCheckSets)
		}
		return map[string]*edgev1.SweepCheckSetV1{}, nil
	}
	if push.GetLeaseVersion() != SweepLeaseCheckSetsVersion {
		return nil, fmt.Errorf("%w: lease_version %d carries slots", ErrSweepLeaseCheckSets, push.GetLeaseVersion())
	}

	sets := make(map[string]*edgev1.SweepCheckSetV1, len(push.GetCheckSets()))
	for i, set := range push.GetCheckSets() {
		key := set.GetCheckSetSha256()
		if len(key) != sha256.Size {
			return nil, fmt.Errorf("%w: check set %d key is %d bytes", ErrSweepLeaseCheckSets, i, len(key))
		}
		if _, dup := sets[string(key)]; dup {
			return nil, fmt.Errorf("%w: check set %d repeats key %x", ErrSweepLeaseCheckSets, i, key)
		}
		if set.GetDigestVersion() == CheckSetDigestVersion {
			if !canonicalChecks(set.GetChecks()) {
				return nil, fmt.Errorf("%w: check set %x is not sorted and de-duplicated", ErrSweepLeaseCheckSets, key)
			}
			if !bytes.Equal(CheckSetDigest(set.GetChecks()), key) {
				return nil, fmt.Errorf("%w: check set %x does not digest to its key", ErrSweepLeaseCheckSets, key)
			}
		}
		sets[string(key)] = set
	}

	referenced := make(map[string]bool, len(sets))
	for i, slot := range push.GetSlots() {
		key := slot.GetPlanHeader().GetCheckSetSha256()
		if _, ok := sets[string(key)]; !ok {
			return nil, fmt.Errorf("%w: slot %d check set %x is not carried", ErrSweepLeaseCheckSets, i, key)
		}
		referenced[string(key)] = true
	}
	if len(referenced) != len(sets) {
		return nil, fmt.Errorf("%w: %d carried check sets referenced by no slot", ErrSweepLeaseCheckSets,
			len(sets)-len(referenced))
	}
	return sets, nil
}

// canonicalChecks reports whether checks are strictly ascending by (mode,
// protocol, port), the order and uniqueness the check-set grammar fixes.
func canonicalChecks(checks []*edgev1.SweepTestV1) bool {
	for i := 1; i < len(checks); i++ {
		if compareCheck(checks[i-1], checks[i]) >= 0 {
			return false
		}
	}
	return true
}

func compareCheck(a, b *edgev1.SweepTestV1) int {
	switch {
	case a.GetMode() != b.GetMode():
		return int(a.GetMode()) - int(b.GetMode())
	case a.GetProtocol() != b.GetProtocol():
		return int(a.GetProtocol()) - int(b.GetProtocol())
	default:
		return int(a.GetPort()) - int(b.GetPort())
	}
}

// SweepCheckSetRunSpec is what one carried check set asks the scanner to run:
// each mode in ascending order, every TCP mode on the same Ports.
type SweepCheckSetRunSpec struct {
	Modes []edgev1.SweepMode
	Ports []uint32
}

// SweepCheckSetRun turns a carried set into the scanner's run shape. The scanner
// runs every TCP mode on every port, so the set must be ICMP at most once (port
// 0) plus each TCP mode on one shared, non-empty port list. Any other set, an
// unknown digest_version, or a mode the edge sweep does not produce (MTR) is
// ErrSweepCheckSetUnsupported.
func SweepCheckSetRun(set *edgev1.SweepCheckSetV1) (SweepCheckSetRunSpec, error) {
	if set.GetDigestVersion() != CheckSetDigestVersion {
		return SweepCheckSetRunSpec{}, fmt.Errorf("%w: digest_version %d", ErrSweepCheckSetUnsupported, set.GetDigestVersion())
	}
	if len(set.GetChecks()) == 0 {
		return SweepCheckSetRunSpec{}, fmt.Errorf("%w: no checks", ErrSweepCheckSetUnsupported)
	}

	portsByMode := make(map[edgev1.SweepMode][]uint32)
	var spec SweepCheckSetRunSpec
	for _, check := range set.GetChecks() {
		mode := check.GetMode()
		switch mode {
		case edgev1.SweepMode_SWEEP_MODE_ICMP:
			if check.GetProtocol() != edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP || check.GetPort() != 0 {
				return SweepCheckSetRunSpec{}, fmt.Errorf("%w: ICMP check is not protocol ICMP port 0", ErrSweepCheckSetUnsupported)
			}
		case edgev1.SweepMode_SWEEP_MODE_TCP_SYN, edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT:
			if check.GetProtocol() != edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP || check.GetPort() == 0 || check.GetPort() > 65535 {
				return SweepCheckSetRunSpec{}, fmt.Errorf("%w: %s check is not protocol TCP on a port", ErrSweepCheckSetUnsupported, mode)
			}
		case edgev1.SweepMode_SWEEP_MODE_UNSPECIFIED:
			return SweepCheckSetRunSpec{}, fmt.Errorf("%w: mode %s", ErrSweepCheckSetUnsupported, mode)
		case edgev1.SweepMode_SWEEP_MODE_MTR:
			return SweepCheckSetRunSpec{}, fmt.Errorf("%w: mode %s", ErrSweepCheckSetUnsupported, mode)
		default:
			return SweepCheckSetRunSpec{}, fmt.Errorf("%w: mode %s", ErrSweepCheckSetUnsupported, mode)
		}
		if _, seen := portsByMode[mode]; !seen {
			spec.Modes = append(spec.Modes, mode)
		}
		portsByMode[mode] = append(portsByMode[mode], check.GetPort())
	}

	if len(portsByMode[edgev1.SweepMode_SWEEP_MODE_ICMP]) > 1 {
		return SweepCheckSetRunSpec{}, fmt.Errorf("%w: ICMP listed more than once", ErrSweepCheckSetUnsupported)
	}
	for _, mode := range spec.Modes {
		if mode == edgev1.SweepMode_SWEEP_MODE_ICMP {
			continue
		}
		ports := portsByMode[mode]
		if spec.Ports == nil {
			spec.Ports = ports
			continue
		}
		if !slices.Equal(spec.Ports, ports) {
			return SweepCheckSetRunSpec{}, fmt.Errorf("%w: TCP modes probe different ports", ErrSweepCheckSetUnsupported)
		}
	}
	return spec, nil
}
