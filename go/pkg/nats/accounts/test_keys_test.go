/*
 * Copyright 2025 Carver Automation Corporation.
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
	"sync"
	"testing"

	"github.com/nats-io/nkeys"
)

const testOperatorSeed = "SOAAFY5ZRTNXZC3KR3DIGXIF2CNEXXT3XPHRW2SMVS7WDDSZEOMAU3HDNY"
const testAccountSeed = "SAAHPPNBNGJS55UFJ25VHHOKBBXFTZRFMOKVOIMD6E23SUDADM2YUDRNRE"

//nolint:gochecknoglobals // test-only globals for sync.Once caching pattern
var (
	testOperatorOnce sync.Once
	testOperator     *Operator
	testOperatorErr  error
)

// newTestOperator returns a cached operator to avoid repeated key generation in tests.
func newTestOperator(t *testing.T) *Operator {
	t.Helper()

	testOperatorOnce.Do(func() {
		testOperator, testOperatorErr = NewOperator(&OperatorConfig{
			Name:         "test-operator",
			OperatorSeed: testOperatorSeed,
		})
	})

	if testOperatorErr != nil {
		t.Fatalf("NewOperator() error = %v", testOperatorErr)
	}

	return testOperator
}

func testOperatorPublicKey(t *testing.T) string {
	t.Helper()

	return publicKeyFromSeed(t, testOperatorSeed)
}

func testAccountPublicKey(t *testing.T) string {
	t.Helper()

	return publicKeyFromSeed(t, testAccountSeed)
}

func publicKeyFromSeed(t *testing.T, seed string) string {
	t.Helper()

	kp, err := nkeys.FromSeed([]byte(seed))
	if err != nil {
		t.Fatalf("nkeys.FromSeed() error = %v", err)
	}

	pubKey, err := kp.PublicKey()
	if err != nil {
		t.Fatalf("kp.PublicKey() error = %v", err)
	}

	return pubKey
}
