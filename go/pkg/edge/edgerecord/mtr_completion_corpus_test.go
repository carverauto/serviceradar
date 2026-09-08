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
	"fmt"
	"strings"
	"testing"
)

// Each row carries the complete leaf input and, only for an admitted value,
// its frozen preimage and verified single-leaf completion root. Elixir reads
// these same rows; rejected dispositions never acquire a hashed preimage.
func TestMtrCompletionDispositionSharedCorpus(t *testing.T) {
	var manifest strings.Builder
	for _, value := range []int32{1, 2, 3, 4, 5, 0, -1, 6, 999} {
		leaf := MtrCompletionLeaf{
			Ordinal: 1, Disposition: MtrTerminalDisposition(value),
			RangeSha256: bytes.Repeat([]byte{0x43}, 32),
		}
		traceHex := "-"
		if value == 1 {
			leaf.TraceID = stableUUID(0x44)
			traceHex = fmt.Sprintf("%x", leaf.TraceID)
		}
		plan := bytes.Repeat([]byte{0x45}, 32)
		leaves := []MtrCompletionLeaf{leaf}
		commitment := MtrOrdinalRangeCommitment(leaves)
		root, err := MtrCompletionRoot(leaves, 0, 1, plan, commitment)
		verdict, preimageHex, rootHex := "reject", "-", "-"
		if value >= 1 && value <= 5 {
			if err != nil {
				t.Fatalf("disposition %d: %v", value, err)
			}
			// Independent literal grammar witness; mtrLeafHash is the private
			// implementation under test and remains private in production.
			preimage := binary.BigEndian.AppendUint64(nil, 2)
			preimage = binary.BigEndian.AppendUint64(preimage, leaf.Ordinal)
			preimage = binary.BigEndian.AppendUint64(preimage, uint64(value))
			preimage = binary.BigEndian.AppendUint64(preimage, uint64(len(leaf.TraceID)))
			preimage = append(preimage, leaf.TraceID...)
			preimage = binary.BigEndian.AppendUint64(preimage, 32)
			preimage = append(preimage, leaf.RangeSha256...)
			if mtrLeafHash(leaf) != sha256.Sum256(preimage) {
				t.Fatalf("disposition %d disagrees with the frozen leaf transcript", value)
			}
			verdict, preimageHex, rootHex = "accept", fmt.Sprintf("%x", preimage), fmt.Sprintf("%x", root)
		} else if err == nil || root != nil {
			t.Fatalf("disposition %d must fail before a root is emitted", value)
		}
		fmt.Fprintf(&manifest, "%d %s %d %s %x %x %x %s %s\n",
			value, verdict, leaf.Ordinal, traceHex, leaf.RangeSha256, plan, commitment, preimageHex, rootHex)
	}
	goldenBytesLocal(t, "mtr_completion_disposition_corpus.txt", []byte(manifest.String()))
}
