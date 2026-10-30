package certpolicy

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestPolicyAdmissionInvalidationAndExpiry(t *testing.T) {
	policy := New()
	defer policy.Close()
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	if !errors.Is(policy.Authorize(a), ErrUnavailable) {
		t.Fatal("empty policy allowed peer")
	}
	now := time.Now()
	snapshot := Snapshot{1, now, now.Add(5 * time.Second), []string{a, b}}
	if err := policy.Apply(snapshot); err != nil {
		t.Fatal(err)
	}
	aClosed, bClosed := make(chan struct{}, 1), make(chan struct{}, 1)
	releaseA, err := policy.Watch(a, func() { aClosed <- struct{}{} })
	if err != nil {
		t.Fatal(err)
	}
	defer releaseA()
	releaseB, err := policy.Watch(b, func() { bClosed <- struct{}{} })
	if err != nil {
		t.Fatal(err)
	}
	defer releaseB()
	// Updating caller-owned storage cannot mutate the installed set.
	snapshot.AllowedFingerprints[0] = b
	if err := policy.Authorize(a); err != nil {
		t.Fatal(err)
	}
	newer := time.Now()
	if err := policy.Apply(Snapshot{1, newer, newer.Add(150 * time.Millisecond), []string{b}}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-aClosed:
	default:
		t.Fatal("revoked session not invalidated")
	}
	select {
	case <-bClosed:
		t.Fatal("unaffected session invalidated")
	default:
	}
	if !errors.Is(policy.Authorize(a), ErrDenied) {
		t.Fatal("revoked peer allowed")
	}
	if !errors.Is(policy.Apply(snapshot), ErrRollback) {
		t.Fatal("older policy accepted")
	}
	if _, err := policy.Watch(a, func() {}); !errors.Is(err, ErrDenied) {
		t.Fatal("revoked peer watch admitted")
	}
	select {
	case <-bClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("expiry did not close session")
	}
	if !errors.Is(policy.Authorize(b), ErrUnavailable) {
		t.Fatal("expired policy allowed peer")
	}
}

func TestPolicyRejectsInvalidRefreshWithoutLosingCurrentPolicy(t *testing.T) {
	policy := New()
	defer policy.Close()
	fp := strings.Repeat("c", 64)
	now := time.Now()
	good := Snapshot{1, now, now.Add(time.Second), []string{fp}}
	if err := policy.Apply(good); err != nil {
		t.Fatal(err)
	}
	if err := policy.Apply(good); err != nil {
		t.Fatal("identical snapshot should be idempotent", err)
	}
	invalid := []Snapshot{
		{2, now, now.Add(time.Second), []string{fp}},
		{1, now, now.Add(31 * time.Second), []string{fp}},
		{1, now, now.Add(time.Second), []string{"not-a-fingerprint"}},
		{1, now, now.Add(time.Second), []string{strings.ToUpper(fp)}},
		{1, now, now.Add(time.Second), []string{}},
	}
	for _, snapshot := range invalid {
		if err := policy.Apply(snapshot); err == nil {
			t.Fatal("invalid or conflicting refresh accepted")
		}
		if err := policy.Authorize(fp); err != nil {
			t.Fatal("invalid refresh discarded valid policy", err)
		}
	}
	policy.Close()
	if !errors.Is(policy.Authorize(fp), ErrClosed) {
		t.Fatal("closed policy allowed peer")
	}
}
