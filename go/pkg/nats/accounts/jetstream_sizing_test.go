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

package accounts

import (
	"errors"
	"reflect"
	"testing"

	"github.com/nats-io/jwt/v2"
)

func envLookup(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		v, ok := values[key]
		return v, ok
	}
}

func TestJetStreamSizingFromEnv(t *testing.T) {
	for _, unset := range []map[string]string{{}, {MaxFileStoreEnv: ""}, {MaxFileStoreEnv: "  "}} {
		sizing, err := JetStreamSizingFromEnv(envLookup(unset))
		if err != nil || sizing != nil {
			t.Errorf("JetStreamSizingFromEnv(%v) = %v, %v; want nil, nil (keep defaults)", unset, sizing, err)
		}
	}

	for value, want := range map[string]int64{
		"30G":          30_000_000_000,
		"100G":         100_000_000_000,
		"30Gi":         30 << 30,
		"512M":         512_000_000,
		"30000000000":  30_000_000_000,
		"500G":         500_000_000_000,
		"1073741824":   1 << 30,
		"2GB":          2 << 30,
		"123456789012": 123456789012,
	} {
		sizing, err := JetStreamSizingFromEnv(envLookup(map[string]string{MaxFileStoreEnv: value}))
		if err != nil || sizing == nil || sizing.DiskStorage != want {
			t.Errorf("JetStreamSizingFromEnv(%q) = %+v, %v; want %d", value, sizing, err, want)
		}
	}

	for _, bad := range []string{"thirty", "0", "-1", "1.5G", "30G\nfoo: 1", "30 G", "$OTHER"} {
		if _, err := JetStreamSizingFromEnv(envLookup(map[string]string{MaxFileStoreEnv: bad})); !errors.Is(err, ErrInvalidMaxFileStore) {
			t.Errorf("JetStreamSizingFromEnv(%q) error = %v, want ErrInvalidMaxFileStore", bad, err)
		}
	}
}

func TestAccountSigner_WithJetStreamSizing(t *testing.T) {
	op := newTestOperator(t)

	result, err := NewAccountSigner(op).WithJetStreamSizing(&JetStreamSizing{DiskStorage: 30_000_000_000}).
		CreateAccount("sized", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	claims, err := jwt.DecodeAccountClaims(result.AccountJWT)
	if err != nil {
		t.Fatal(err)
	}

	got := claims.Limits.JetStreamLimits
	want := jwt.JetStreamLimits{
		MemoryStorage:        defaultJetStreamMemoryBytes,
		DiskStorage:          30_000_000_000,
		Streams:              defaultJetStreamStreamLimit,
		Consumer:             defaultJetStreamConsumerLimit,
		MaxAckPending:        defaultJetStreamMaxAckPending,
		MemoryMaxStreamBytes: defaultJetStreamMemoryMaxBytes,
		DiskMaxStreamBytes:   0,
		MaxBytesRequired:     true,
	}

	if got != want {
		t.Fatalf("sized JetStream limits = %+v, want %+v", got, want)
	}

	unsized, err := NewAccountSigner(op).WithJetStreamSizing(nil).CreateAccount("unsized", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	defaults, err := jwt.DecodeAccountClaims(unsized.AccountJWT)
	if err != nil {
		t.Fatal(err)
	}

	if defaults.Limits.DiskStorage != defaultJetStreamDiskBytes || defaults.Limits.DiskMaxStreamBytes != defaultJetStreamDiskMaxBytes {
		t.Fatalf("a nil sizing changed the default quota: %+v", defaults.Limits.JetStreamLimits)
	}
}

func TestAccountSigner_ResizeAccountJetStream(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	seed, err := func() (string, error) {
		s, _, err := GenerateAccountKey()
		return s, err
	}()
	if err != nil {
		t.Fatal(err)
	}

	// An account issued with the default quota plus mappings, exports and a
	// revocation that the resize must keep.
	_, original, err := signer.SignAccountJWT(
		"resize-me",
		seed,
		&AccountLimits{MaxConnections: 42},
		[]SubjectMapping{{From: "custom.>", To: "{{namespace}}.custom.>"}},
		[]StreamExport{{Name: "custom", Subject: "{{namespace}}.custom.>"}},
		nil,
		[]string{"UAQ5OVH3LNKY7GLOKVQTJA3M7B3PVLI4OFB5XEWBUOC5V3QCZ5WQ5VZL"},
	)
	if err != nil {
		t.Fatal(err)
	}

	before, err := jwt.DecodeAccountClaims(original)
	if err != nil {
		t.Fatal(err)
	}

	sizing := JetStreamSizing{DiskStorage: 30_000_000_000}

	resized, changed, err := signer.ResizeAccountJetStream(original, sizing)
	if err != nil || !changed {
		t.Fatalf("resize of a default-quota account: changed=%v err=%v", changed, err)
	}

	after, err := jwt.DecodeAccountClaims(resized)
	if err != nil {
		t.Fatal(err)
	}

	if after.Subject != before.Subject || after.Name != before.Name || after.Issuer != op.PublicKey() {
		t.Fatalf("identity changed: %s/%s -> %s/%s", before.Name, before.Subject, after.Name, after.Subject)
	}

	if !reflect.DeepEqual(after.Mappings, before.Mappings) || !reflect.DeepEqual(after.Exports, before.Exports) ||
		!reflect.DeepEqual(after.Revocations, before.Revocations) || after.Limits.Conn != 42 {
		t.Fatal("resize dropped a claim other than the JetStream quota")
	}

	js := after.Limits.JetStreamLimits
	if js.DiskStorage != 30_000_000_000 || js.DiskMaxStreamBytes != 0 || !js.MaxBytesRequired ||
		js.MemoryStorage != defaultJetStreamMemoryBytes || js.Streams != defaultJetStreamStreamLimit {
		t.Fatalf("resized limits = %+v", js)
	}

	again, changed, err := signer.ResizeAccountJetStream(resized, sizing)
	if err != nil || changed || again != resized {
		t.Fatalf("second resize must be a no-op: changed=%v err=%v", changed, err)
	}

	otherSeed, _, err := GenerateOperatorKey()
	if err != nil {
		t.Fatal(err)
	}

	other, err := NewOperator(&OperatorConfig{Name: "other", OperatorSeed: otherSeed})
	if err != nil {
		t.Fatal(err)
	}

	if _, _, err := NewAccountSigner(other).ResizeAccountJetStream(original, sizing); !errors.Is(err, ErrAccountNotIssuedByOperator) {
		t.Fatalf("resize by another operator: err = %v, want ErrAccountNotIssuedByOperator", err)
	}
}
