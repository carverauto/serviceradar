// Package certpolicy enforces the authority's short-lived certificate allowlist.
// Apply accepts only snapshots obtained through an authenticated control-plane
// channel. It is not a signature verifier or a replacement for TLS PKIX checks.
package certpolicy

import (
	"encoding/hex"
	"errors"
	"maps"
	"strings"
	"sync"
	"time"
)

const MaxValidity = 30 * time.Second

var (
	ErrUnavailable         = errors.New("certificate policy unavailable or expired")
	ErrDenied              = errors.New("peer certificate is not authorized")
	ErrRollback            = errors.New("certificate policy snapshot is older than current policy")
	ErrClosed              = errors.New("certificate policy store closed")
	errPolicyValidity      = errors.New("invalid certificate policy validity or version")
	errPolicyFingerprint   = errors.New("invalid certificate fingerprint")
	errPolicyWatchCallback = errors.New("certificate policy watch requires invalidation callback")
)

// Snapshot is the derived transport view of the core authority snapshot. The
// authority alone resolves component generations, validity and revocation.
type Snapshot struct {
	Version             int       `json:"version"`
	GeneratedAt         time.Time `json:"generated_at"`
	ValidUntil          time.Time `json:"valid_until"`
	AllowedFingerprints []string  `json:"allowed_fingerprints"`
}

type watch struct {
	fingerprint string
	invalidate  func()
}

// Store begins fail-closed. Unmanaged installations do not construct or attach
// one. It owns expiry timers; callers own transport lifetimes and call releases.
type Store struct {
	mu       sync.Mutex
	snapshot Snapshot
	allowed  map[string]struct{}
	watches  map[uint64]watch
	nextID   uint64
	epoch    uint64
	timer    *time.Timer
	closed   bool
	deadline time.Time
}

func New() *Store { return &Store{watches: make(map[uint64]watch)} }

// Apply installs an authenticated snapshot and invalidates affected sessions.
// Invalid snapshots leave the last valid policy in place until its deadline.
func (s *Store) Apply(snapshot Snapshot) error {
	now := time.Now()
	if snapshot.Version != 1 || snapshot.GeneratedAt.IsZero() ||
		!snapshot.ValidUntil.After(snapshot.GeneratedAt) || !snapshot.ValidUntil.After(now) ||
		snapshot.ValidUntil.Sub(snapshot.GeneratedAt) > MaxValidity ||
		snapshot.GeneratedAt.After(now.Add(5*time.Second)) {
		return errPolicyValidity
	}
	allowed := make(map[string]struct{}, len(snapshot.AllowedFingerprints))
	for _, fp := range snapshot.AllowedFingerprints {
		raw, err := hex.DecodeString(fp)
		if err != nil || len(raw) != 32 || fp != strings.ToLower(fp) {
			return errPolicyFingerprint
		}
		allowed[fp] = struct{}{}
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrClosed
	}
	if snapshot.GeneratedAt.Before(s.snapshot.GeneratedAt) {
		s.mu.Unlock()
		return ErrRollback
	}
	if snapshot.GeneratedAt.Equal(s.snapshot.GeneratedAt) {
		equal := snapshot.ValidUntil.Equal(s.snapshot.ValidUntil) && maps.Equal(allowed, s.allowed)
		s.mu.Unlock()
		if equal {
			return nil
		}
		return ErrRollback
	}
	// Copy caller-owned slices so mutation cannot alter the installed policy.
	snapshot.AllowedFingerprints = append([]string(nil), snapshot.AllowedFingerprints...)
	s.snapshot, s.allowed = snapshot, allowed
	// Use a local monotonic deadline; a backwards wall-clock adjustment must
	// not reopen an expired policy or extend its maximum lifetime.
	lifetime := min(time.Until(snapshot.ValidUntil), MaxValidity)
	s.deadline = now.Add(lifetime)
	s.epoch++
	epoch := s.epoch
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = time.AfterFunc(lifetime, func() { s.expire(epoch) })
	invalidated := s.removeDeniedLocked(false)
	s.mu.Unlock()
	invalidate(invalidated)
	return nil
}

func (s *Store) Authorize(fingerprint string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authorizeLocked(fingerprint)
}

func (s *Store) authorizeLocked(fingerprint string) error {
	if s.closed {
		return ErrClosed
	}
	if !time.Now().Before(s.deadline) {
		return ErrUnavailable
	}
	if _, ok := s.allowed[fingerprint]; !ok {
		return ErrDenied
	}
	return nil
}

// Watch atomically checks admission and registers an active transport. This
// closes the gap between a successful handshake and a concurrent policy update.
// onInvalid must promptly close the transport or enqueue its disconnection; it
// runs outside the store lock. release is idempotent and removes a closed peer.
func (s *Store) Watch(fingerprint string, onInvalid func()) (release func(), err error) {
	if onInvalid == nil {
		return nil, errPolicyWatchCallback
	}
	s.mu.Lock()
	if err := s.authorizeLocked(fingerprint); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	s.nextID++
	id := s.nextID
	s.watches[id] = watch{fingerprint, onInvalid}
	s.mu.Unlock()
	return func() { s.mu.Lock(); delete(s.watches, id); s.mu.Unlock() }, nil
}

func (s *Store) expire(epoch uint64) {
	s.mu.Lock()
	if epoch != s.epoch {
		s.mu.Unlock()
		return
	}
	invalidated := s.removeDeniedLocked(true)
	s.mu.Unlock()
	invalidate(invalidated)
}

func (s *Store) removeDeniedLocked(all bool) []func() {
	callbacks := make([]func(), 0)
	for id, peer := range s.watches {
		if _, ok := s.allowed[peer.fingerprint]; all || !ok {
			callbacks = append(callbacks, peer.invalidate)
			delete(s.watches, id)
		}
	}
	return callbacks
}

func invalidate(callbacks []func()) {
	for _, callback := range callbacks {
		callback()
	}
}

func (s *Store) Close() {
	s.mu.Lock()
	s.closed = true
	s.epoch++
	if s.timer != nil {
		s.timer.Stop()
	}
	invalidated := s.removeDeniedLocked(true)
	s.mu.Unlock()
	invalidate(invalidated)
}
