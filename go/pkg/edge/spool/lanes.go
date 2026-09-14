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

// Per-lane spool generations (task 2.21 of openspec/changes/unify-sweep-results-proto).
//
// A GENERATION is one Spool bound to ONE (route profile, traffic class) lane and
// to one frozen trust namespace: the network_scope_id and authenticated agent
// identity every record in it was appended under. Each lane owns its own open
// generation, sequence space, and reclamation (resolved) watermark, so bulk,
// interactive, and recovery lanes append and reclaim CONCURRENTLY. There is no
// agent-wide open generation and no lock shared across lanes on the append path.
//
// Single scope is an AUTHENTICATED-AGENT invariant: a LaneSet serves the one
// session identity it was opened with, and an append presenting any other
// network_scope_id or agent identity is refused PERMANENTLY. It is not enforced
// by serializing scopes.
//
// Refusals come in exactly two classes. ErrRotationRequired is RETRYABLE: the
// append was valid, nothing was written, and the producer retries the SAME append
// once the lane has rotated. ErrPermanent covers only a malformed lane (or
// malformed input) and an unauthorized scope/agent identity.
//
// Closed-but-unreclaimed generations stay on disk beside the lane's open one and
// remain independently readable and resolvable under their own frozen identity,
// including after a restart under a different session identity. Deleting a
// reclaimed generation is NOT here: that needs the coverage proof (task 2.28).
//
// On-disk layout, all directories 0700:
//
//	<root>/<route profile>-<traffic class>/<ordinal:020d>-<spool id hex>/
//	    identity   frozen, CRC-checked, written once before the first append
//	    closed     presence marks the generation closed; never removed
//	    lane.seg   records (see Spool)
//	    resolved   reclamation watermark (see Spool)
//
// A generation directory is prepared under a ".tmp-" name and renamed into place
// only after its identity is durable, so every generation directory that can
// hold a record has a frozen identity.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	identityFile = "identity"
	closedFile   = "closed"
	tmpPrefix    = ".tmp-"

	identityMagic   = 0x53524749 // "SRGI"
	identityVersion = 1

	// identityFixedLen is magic(4)+version(1)+routeProfile(4)+trafficClass(4)+
	// ordinal(8)+spoolID(16)+networkScopeID(16)+agentLen(1).
	identityFixedLen = 54
	uuidLen          = 16
)

// LaneKey is the platform lane a generation is bound to: one (route profile,
// traffic class) pair. It is the scheduler's key, so the spool and the scheduler
// cannot disagree about what a lane is or when one is malformed.
type LaneKey = fairsched.LaneKey

// Refusal classes. Every append refusal wraps exactly one of them, so a producer
// decides retry-vs-drop with errors.Is and never by matching a specific reason.
var (
	// ErrRetryable marks a refusal of a VALID append that wrote nothing; the
	// producer retries the same append.
	ErrRetryable = errors.New("spool: retryable refusal")
	// ErrPermanent marks a refusal no retry can fix: a malformed lane or input,
	// or a scope/agent identity the authenticated session does not authorize.
	ErrPermanent = errors.New("spool: permanent refusal")
)

// Specific refusals, each wrapping its class.
var (
	// ErrRotationRequired (ROTATION_REQUIRED) is returned when the lane's open
	// generation must rotate before it can take the append.
	ErrRotationRequired = fmt.Errorf("%w: ROTATION_REQUIRED", ErrRetryable)
	// ErrLaneInvalid is returned for a lane that is not a declared, non-zero
	// member of the platform taxonomy.
	ErrLaneInvalid = fmt.Errorf("%w: malformed lane", ErrPermanent)
	// ErrScopeUnauthorized is returned for a network_scope_id the session does
	// not authorize.
	ErrScopeUnauthorized = fmt.Errorf("%w: network_scope_id not authorized for this agent", ErrPermanent)
	// ErrAgentUnauthorized is returned for an agent identity other than the
	// authenticated session's.
	ErrAgentUnauthorized = fmt.Errorf("%w: agent identity not authorized for this session", ErrPermanent)
)

var (
	// ErrSessionIdentity is returned by OpenLanes for a malformed session identity.
	ErrSessionIdentity = errors.New("spool: invalid session identity")
	// ErrCorruptGeneration is returned by OpenLanes when on-disk generation state
	// cannot be trusted: an unreadable or inconsistent frozen identity, an
	// unrecognized entry, or more than one open generation on a lane. Recovery
	// stops rather than guessing which identity a record belongs to.
	ErrCorruptGeneration = errors.New("spool: corrupt generation state")
	// ErrLaneSetClosed is returned by operations on a closed LaneSet.
	ErrLaneSetClosed = errors.New("spool: lane set is closed")
)

// Identity is the trust namespace a generation freezes: the network scope and
// the authenticated agent principal (the ASCII component id, equal to
// producer_context.origin_principal_id).
type Identity struct {
	NetworkScopeID []byte
	AgentID        []byte
}

func (id Identity) clone() Identity {
	return Identity{
		NetworkScopeID: bytes.Clone(id.NetworkScopeID),
		AgentID:        bytes.Clone(id.AgentID),
	}
}

func (id Identity) equal(o Identity) bool {
	return bytes.Equal(id.NetworkScopeID, o.NetworkScopeID) && bytes.Equal(id.AgentID, o.AgentID)
}

func (id Identity) validate() error {
	if err := edgerecord.ValidateCanonicalUUID(id.NetworkScopeID); err != nil {
		return fmt.Errorf("network_scope_id: %w", err)
	}
	if err := edgerecord.ValidateAuthenticatedPrincipal(id.AgentID); err != nil {
		return fmt.Errorf("agent id: %w", err)
	}
	return nil
}

// GenerationIdentity is everything a generation froze when it was opened.
type GenerationIdentity struct {
	Lane LaneKey
	// Ordinal orders generations within a lane, starting at 1.
	Ordinal uint64
	// SpoolID is the generation's UUIDv7, the frame spool_id.
	SpoolID  []byte
	Identity Identity
}

func (g GenerationIdentity) clone() GenerationIdentity {
	g.SpoolID = bytes.Clone(g.SpoolID)
	g.Identity = g.Identity.clone()
	return g
}

// Receipt identifies a durably appended record: its generation and sequence.
type Receipt struct {
	Generation GenerationIdentity
	Sequence   uint64
}

// Generation is one lane generation. Appends go through LaneSet, which checks the
// frozen identity; a Generation exposes only reads and reclamation, which stay
// available after it closes.
type Generation struct {
	id     GenerationIdentity
	dir    string
	spool  *Spool
	closed atomic.Bool
}

// Identity returns the generation's frozen identity.
func (g *Generation) Identity() GenerationIdentity { return g.id.clone() }

// Closed reports whether the generation no longer accepts appends.
func (g *Generation) Closed() bool { return g.closed.Load() }

// NextSequence returns the sequence the generation's next append would assign.
func (g *Generation) NextSequence() uint64 { return g.spool.NextSequence() }

// Resolved returns the generation's own reclamation watermark.
func (g *Generation) Resolved() uint64 { return g.spool.Resolved() }

// Resolve advances the generation's own reclamation watermark; see Spool.Resolve.
func (g *Generation) Resolve(through uint64) error { return g.spool.Resolve(through) }

// ScanFrom streams the generation's unresolved records; see Spool.ScanFrom.
func (g *Generation) ScanFrom(after uint64, visit func(Record) bool) error {
	return g.spool.ScanFrom(after, visit)
}

// Unresolved returns the generation's unresolved records; see Spool.Unresolved.
func (g *Generation) Unresolved() ([]Record, error) { return g.spool.Unresolved() }

// lane is one lane's generation bookkeeping. Its mutex is the only lock an append
// holds while it writes, so lanes never wait on each other.
type lane struct {
	key LaneKey
	dir string

	mu              sync.Mutex
	open            *Generation
	retained        []*Generation // closed-but-unreclaimed, ordinal order
	nextOrdinal     uint64
	rotationPending bool
	shut            bool
}

// LaneSet is the agent's spool: one open generation per lane under one
// authenticated session identity. It is safe for concurrent use.
type LaneSet struct {
	root    string
	session Identity

	mu     sync.Mutex // guards lanes and closed; never held across I/O on a lane
	lanes  map[LaneKey]*lane
	closed bool
}

// OpenLanes opens (creating if needed) the lane set rooted at root for the given
// authenticated session identity and recovers every generation on disk.
//
// A recovered OPEN generation frozen under a different identity (the agent was
// re-enrolled) keeps that identity and marks its lane rotation-required: it is
// never appended to under the new identity, and it stays recoverable after it
// closes.
func OpenLanes(root string, session Identity) (*LaneSet, error) {
	if err := session.validate(); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrSessionIdentity, err)
	}
	if err := os.MkdirAll(root, dirPerm); err != nil {
		return nil, fmt.Errorf("spool: mkdir lane root: %w", err)
	}
	if err := fsyncDir(root); err != nil {
		return nil, err
	}

	ls := &LaneSet{
		root:    root,
		session: session.clone(),
		lanes:   make(map[LaneKey]*lane),
	}

	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("spool: read lane root: %w", err)
	}
	for _, e := range entries {
		key, ok := parseLaneDir(e.Name())
		if !ok || !e.IsDir() {
			_ = ls.closeAll()
			return nil, fmt.Errorf("%w: unrecognized lane entry %q", ErrCorruptGeneration, e.Name())
		}
		l, err := ls.recoverLane(key)
		if err != nil {
			_ = ls.closeAll()
			return nil, err
		}
		ls.lanes[key] = l
	}

	return ls, nil
}

// Append durably appends one record to the lane's open generation, opening one
// if the lane has none. presented is the scope and agent identity the record
// claims; it must equal the session identity.
//
// Refusals wrap ErrRetryable (ErrRotationRequired) or ErrPermanent and write
// nothing. Storage failures are returned unclassified.
func (ls *LaneSet) Append(key LaneKey, presented Identity, eventID, body []byte) (Receipt, error) {
	if !key.Valid() {
		return Receipt{}, fmt.Errorf("%w: %s", ErrLaneInvalid, key)
	}
	if err := ls.authorize(presented); err != nil {
		return Receipt{}, err
	}
	if len(eventID) != uuidLen {
		return Receipt{}, fmt.Errorf("%w: %w: got %d", ErrPermanent, ErrEventIDLength, len(eventID))
	}

	l, err := ls.lane(key)
	if err != nil {
		return Receipt{}, err
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.shut {
		return Receipt{}, ErrLaneSetClosed
	}
	if l.rotationPending {
		return Receipt{}, fmt.Errorf("%w: lane %s", ErrRotationRequired, key)
	}
	if l.open == nil {
		if err := ls.openGeneration(l); err != nil {
			return Receipt{}, err
		}
	}
	// A generation's identity is frozen: an append never lands in a generation
	// frozen under another identity. Recovery marks such a lane pending, so this
	// is the same answer reached without trusting that bookkeeping.
	if !l.open.id.Identity.equal(presented) {
		return Receipt{}, fmt.Errorf("%w: lane %s open generation is frozen under another identity", ErrRotationRequired, key)
	}

	seq, err := l.open.spool.Append(eventID, body)
	if err != nil {
		return Receipt{}, err
	}
	return Receipt{Generation: l.open.id.clone(), Sequence: seq}, nil
}

// RequireRotation marks the lane's open generation as needing rotation: until
// Rotate runs, appends to that lane answer ErrRotationRequired. Other lanes are
// unaffected. A lane with no open generation needs no rotation.
func (ls *LaneSet) RequireRotation(key LaneKey) error {
	if !key.Valid() {
		return fmt.Errorf("%w: %s", ErrLaneInvalid, key)
	}
	l, err := ls.lane(key)
	if err != nil {
		return err
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.shut {
		return ErrLaneSetClosed
	}
	if l.open != nil {
		l.rotationPending = true
	}
	return nil
}

// Rotate durably closes the lane's open generation, which stays recoverable under
// its frozen identity, and opens a successor under the session identity with a
// fresh spool id and sequence space. Only this lane is touched.
//
// The close marker is durable before the successor exists, so a crash between
// the two leaves the lane with no open generation and the next append opens one.
func (ls *LaneSet) Rotate(key LaneKey) (GenerationIdentity, error) {
	if !key.Valid() {
		return GenerationIdentity{}, fmt.Errorf("%w: %s", ErrLaneInvalid, key)
	}
	l, err := ls.lane(key)
	if err != nil {
		return GenerationIdentity{}, err
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.shut {
		return GenerationIdentity{}, ErrLaneSetClosed
	}
	if l.open != nil {
		if err := writeClosedMarker(l.open.dir); err != nil {
			return GenerationIdentity{}, err
		}
		l.open.closed.Store(true)
		l.retained = append(l.retained, l.open)
		l.open = nil
	}
	l.rotationPending = false

	if err := ls.openGeneration(l); err != nil {
		return GenerationIdentity{}, err
	}
	return l.open.id.clone(), nil
}

// OpenGeneration returns the lane's open generation, if it has one.
func (ls *LaneSet) OpenGeneration(key LaneKey) (*Generation, bool) {
	l := ls.existingLane(key)
	if l == nil {
		return nil, false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.open, l.open != nil
}

// Generations returns every generation the lane holds, closed-but-unreclaimed
// ones first, in ordinal order.
func (ls *LaneSet) Generations(key LaneKey) []*Generation {
	l := ls.existingLane(key)
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	out := slices.Clone(l.retained)
	if l.open != nil {
		out = append(out, l.open)
	}
	return out
}

// Lanes returns every lane that holds or has held a generation.
func (ls *LaneSet) Lanes() []LaneKey {
	ls.mu.Lock()
	defer ls.mu.Unlock()
	out := make([]LaneKey, 0, len(ls.lanes))
	for k := range ls.lanes {
		out = append(out, k)
	}
	slices.SortFunc(out, func(a, b LaneKey) int {
		if a.RouteProfile != b.RouteProfile {
			return int(a.RouteProfile) - int(b.RouteProfile)
		}
		return int(a.TrafficClass) - int(b.TrafficClass)
	})
	return out
}

// Close closes every generation's segment. It waits for in-flight appends.
func (ls *LaneSet) Close() error {
	ls.mu.Lock()
	if ls.closed {
		ls.mu.Unlock()
		return nil
	}
	ls.closed = true
	ls.mu.Unlock()
	return ls.closeAll()
}

func (ls *LaneSet) closeAll() error {
	ls.mu.Lock()
	lanes := make([]*lane, 0, len(ls.lanes))
	for _, l := range ls.lanes {
		lanes = append(lanes, l)
	}
	ls.mu.Unlock()

	var errs []error
	for _, l := range lanes {
		l.mu.Lock()
		l.shut = true
		for _, g := range l.retained {
			errs = append(errs, g.spool.Close())
		}
		if l.open != nil {
			errs = append(errs, l.open.spool.Close())
		}
		l.mu.Unlock()
	}
	return errors.Join(errs...)
}

// authorize enforces the single-scope authenticated-agent invariant.
func (ls *LaneSet) authorize(presented Identity) error {
	if edgerecord.ValidateCanonicalUUID(presented.NetworkScopeID) != nil ||
		!bytes.Equal(presented.NetworkScopeID, ls.session.NetworkScopeID) {
		return ErrScopeUnauthorized
	}
	if edgerecord.ValidateAuthenticatedPrincipal(presented.AgentID) != nil ||
		!bytes.Equal(presented.AgentID, ls.session.AgentID) {
		return ErrAgentUnauthorized
	}
	return nil
}

// lane returns the lane's bookkeeping, creating it on first use.
func (ls *LaneSet) lane(key LaneKey) (*lane, error) {
	ls.mu.Lock()
	defer ls.mu.Unlock()
	if ls.closed {
		return nil, ErrLaneSetClosed
	}
	l, ok := ls.lanes[key]
	if !ok {
		l = &lane{key: key, dir: filepath.Join(ls.root, laneDirName(key)), nextOrdinal: 1}
		ls.lanes[key] = l
	}
	return l, nil
}

func (ls *LaneSet) existingLane(key LaneKey) *lane {
	ls.mu.Lock()
	defer ls.mu.Unlock()
	return ls.lanes[key]
}

// openGeneration creates the lane's next generation under the session identity
// and makes it the open one. The caller holds l.mu.
func (ls *LaneSet) openGeneration(l *lane) error {
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return fmt.Errorf("spool: generate spool id: %w", err)
	}
	id := GenerationIdentity{
		Lane:     l.key,
		Ordinal:  l.nextOrdinal,
		SpoolID:  spoolID,
		Identity: ls.session.clone(),
	}

	if err := os.MkdirAll(l.dir, dirPerm); err != nil {
		return fmt.Errorf("spool: mkdir lane: %w", err)
	}
	if err := fsyncDir(ls.root); err != nil {
		return err
	}

	name := generationDirName(id.Ordinal, id.SpoolID)
	tmp := filepath.Join(l.dir, tmpPrefix+name)
	final := filepath.Join(l.dir, name)
	if err := os.Mkdir(tmp, dirPerm); err != nil {
		return fmt.Errorf("spool: mkdir generation: %w", err)
	}
	identityPath := filepath.Join(tmp, identityFile)
	if err := os.WriteFile(identityPath, encodeIdentity(id), filePerm); err != nil {
		return fmt.Errorf("spool: write generation identity: %w", err)
	}
	if err := fsyncFile(identityPath); err != nil {
		return err
	}
	if err := fsyncDir(tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		return fmt.Errorf("spool: publish generation: %w", err)
	}
	// Published: the ordinal is spent whether or not the segment opens, so a
	// retry can never publish a second generation under the same ordinal.
	l.nextOrdinal++
	if err := fsyncDir(l.dir); err != nil {
		return err
	}

	sp, err := Open(final)
	if err != nil {
		// It holds no record. Close it so a retry's successor is the lane's only
		// open generation; if even that fails, recovery fails stop on two open
		// generations rather than guessing.
		_ = writeClosedMarker(final)
		return err
	}
	l.open = &Generation{id: id, dir: final, spool: sp}
	return nil
}

// recoverLane loads one lane's generations from disk.
func (ls *LaneSet) recoverLane(key LaneKey) (*lane, error) {
	l := &lane{key: key, dir: filepath.Join(ls.root, laneDirName(key)), nextOrdinal: 1}

	entries, err := os.ReadDir(l.dir)
	if err != nil {
		return nil, fmt.Errorf("spool: read lane %s: %w", key, err)
	}

	var gens []*Generation
	closeGens := func() {
		for _, g := range gens {
			_ = g.spool.Close()
		}
	}

	removedTmp := false
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, tmpPrefix) {
			// A generation still being prepared never had its Spool opened, so it
			// holds no record: discard it.
			if err := os.RemoveAll(filepath.Join(l.dir, name)); err != nil {
				closeGens()
				return nil, fmt.Errorf("spool: discard generation preparation %q: %w", name, err)
			}
			removedTmp = true
			continue
		}
		g, err := recoverGeneration(l, e)
		if err != nil {
			closeGens()
			return nil, err
		}
		gens = append(gens, g)
	}
	if removedTmp {
		if err := fsyncDir(l.dir); err != nil {
			closeGens()
			return nil, err
		}
	}

	// ReadDir sorts by name and names lead with the zero-padded ordinal.
	for _, g := range gens {
		if g.id.Ordinal >= l.nextOrdinal {
			l.nextOrdinal = g.id.Ordinal + 1
		}
		if !g.Closed() {
			if l.open != nil {
				closeGens()
				return nil, fmt.Errorf("%w: lane %s has more than one open generation", ErrCorruptGeneration, key)
			}
			l.open = g
			continue
		}
		if l.open != nil {
			// Rotation closes a generation before its successor exists, so an
			// open generation followed by a closed one was not written by us.
			closeGens()
			return nil, fmt.Errorf("%w: lane %s has a closed generation after its open one", ErrCorruptGeneration, key)
		}
		l.retained = append(l.retained, g)
	}

	if l.open != nil && !l.open.id.Identity.equal(ls.session) {
		l.rotationPending = true
	}
	return l, nil
}

func recoverGeneration(l *lane, e os.DirEntry) (*Generation, error) {
	name := e.Name()
	ordinal, spoolID, ok := parseGenerationDir(name)
	if !ok || !e.IsDir() {
		return nil, fmt.Errorf("%w: lane %s: unrecognized entry %q", ErrCorruptGeneration, l.key, name)
	}
	dir := filepath.Join(l.dir, name)

	raw, err := os.ReadFile(filepath.Join(dir, identityFile))
	if err != nil {
		return nil, fmt.Errorf("%w: generation %q identity: %w", ErrCorruptGeneration, name, err)
	}
	id, err := decodeIdentity(raw)
	if err != nil {
		return nil, fmt.Errorf("%w: generation %q: %w", ErrCorruptGeneration, name, err)
	}
	if id.Lane != l.key || id.Ordinal != ordinal || !bytes.Equal(id.SpoolID, spoolID) {
		return nil, fmt.Errorf("%w: generation %q identity does not match its location", ErrCorruptGeneration, name)
	}

	closed, err := exists(filepath.Join(dir, closedFile))
	if err != nil {
		return nil, err
	}
	sp, err := Open(dir)
	if err != nil {
		return nil, err
	}
	g := &Generation{id: id, dir: dir, spool: sp}
	g.closed.Store(closed)
	return g, nil
}

// --- naming ---

func laneDirName(key LaneKey) string {
	return fmt.Sprintf("%d-%d", int32(key.RouteProfile), int32(key.TrafficClass))
}

// parseLaneDir accepts only the canonical rendering of a valid lane.
func parseLaneDir(name string) (LaneKey, bool) {
	rp, tc, ok := strings.Cut(name, "-")
	if !ok {
		return LaneKey{}, false
	}
	rpv, err1 := strconv.ParseInt(rp, 10, 32)
	tcv, err2 := strconv.ParseInt(tc, 10, 32)
	if err1 != nil || err2 != nil {
		return LaneKey{}, false
	}
	key := LaneKey{
		RouteProfile: edgev1.EdgeRecordRouteProfile(rpv),
		TrafficClass: edgev1.EdgeRecordTrafficClass(tcv),
	}
	if !key.Valid() || laneDirName(key) != name {
		return LaneKey{}, false
	}
	return key, true
}

func generationDirName(ordinal uint64, spoolID []byte) string {
	return fmt.Sprintf("%020d-%x", ordinal, spoolID)
}

// parseGenerationDir accepts only the canonical rendering.
func parseGenerationDir(name string) (uint64, []byte, bool) {
	ord, hexID, ok := strings.Cut(name, "-")
	if !ok {
		return 0, nil, false
	}
	ordinal, err := strconv.ParseUint(ord, 10, 64)
	if err != nil || ordinal == 0 {
		return 0, nil, false
	}
	var spoolID []byte
	if _, err := fmt.Sscanf(hexID, "%x", &spoolID); err != nil || len(spoolID) != uuidLen {
		return 0, nil, false
	}
	if generationDirName(ordinal, spoolID) != name {
		return 0, nil, false
	}
	return ordinal, spoolID, true
}

// --- frozen identity ---

func encodeIdentity(id GenerationIdentity) []byte {
	agent := id.Identity.AgentID
	buf := make([]byte, identityFixedLen+len(agent)+bodyCRCLen)

	binary.LittleEndian.PutUint32(buf[0:], identityMagic)
	buf[4] = identityVersion
	binary.LittleEndian.PutUint32(buf[5:], uint32(id.Lane.RouteProfile))
	binary.LittleEndian.PutUint32(buf[9:], uint32(id.Lane.TrafficClass))
	binary.LittleEndian.PutUint64(buf[13:], id.Ordinal)
	copy(buf[21:37], id.SpoolID)
	copy(buf[37:53], id.Identity.NetworkScopeID)
	buf[53] = byte(len(agent)) // bounded by edgerecord.MaxPrincipalBytes
	copy(buf[identityFixedLen:], agent)

	end := identityFixedLen + len(agent)
	binary.LittleEndian.PutUint32(buf[end:], crc32.Checksum(buf[:end], crcTable))
	return buf
}

var errIdentityEncoding = errors.New("invalid identity encoding")

func decodeIdentity(b []byte) (GenerationIdentity, error) {
	if len(b) < identityFixedLen+bodyCRCLen {
		return GenerationIdentity{}, fmt.Errorf("%w: short", errIdentityEncoding)
	}
	end := len(b) - bodyCRCLen
	if binary.LittleEndian.Uint32(b[end:]) != crc32.Checksum(b[:end], crcTable) {
		return GenerationIdentity{}, fmt.Errorf("%w: checksum mismatch", errIdentityEncoding)
	}
	if binary.LittleEndian.Uint32(b[0:]) != identityMagic || b[4] != identityVersion {
		return GenerationIdentity{}, fmt.Errorf("%w: magic or version", errIdentityEncoding)
	}
	if identityFixedLen+int(b[53]) != end {
		return GenerationIdentity{}, fmt.Errorf("%w: agent length", errIdentityEncoding)
	}

	id := GenerationIdentity{
		Lane: LaneKey{
			RouteProfile: edgev1.EdgeRecordRouteProfile(int32(binary.LittleEndian.Uint32(b[5:]))),
			TrafficClass: edgev1.EdgeRecordTrafficClass(int32(binary.LittleEndian.Uint32(b[9:]))),
		},
		Ordinal: binary.LittleEndian.Uint64(b[13:]),
		SpoolID: bytes.Clone(b[21:37]),
		Identity: Identity{
			NetworkScopeID: bytes.Clone(b[37:53]),
			AgentID:        bytes.Clone(b[identityFixedLen:end]),
		},
	}
	if !id.Lane.Valid() {
		return GenerationIdentity{}, fmt.Errorf("%w: lane", errIdentityEncoding)
	}
	if err := edgerecord.ValidateUUIDv7(id.SpoolID); err != nil {
		return GenerationIdentity{}, fmt.Errorf("%w: spool id: %w", errIdentityEncoding, err)
	}
	if err := id.Identity.validate(); err != nil {
		return GenerationIdentity{}, fmt.Errorf("%w: %w", errIdentityEncoding, err)
	}
	return id, nil
}

// --- close marker ---

func writeClosedMarker(dir string) error {
	path := filepath.Join(dir, closedFile)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, filePerm)
	if err != nil {
		return fmt.Errorf("spool: create close marker: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("spool: fsync close marker: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("spool: close marker: %w", err)
	}
	return fsyncDir(dir)
}

func exists(path string) (bool, error) {
	_, err := os.Stat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return false, fmt.Errorf("spool: stat %q: %w", path, err)
}
