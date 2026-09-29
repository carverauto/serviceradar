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

package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"testing"

	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/proto"
)

// pushedConfigChunks splits resp the way the gateway does for a control-stream
// push: the encoded response in fixed-size payload slices sharing one checksum.
func pushedConfigChunks(t *testing.T, resp *proto.AgentConfigResponse, chunkSize int) []*proto.AgentConfigChunk {
	t.Helper()

	payload, err := goproto.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal config response: %v", err)
	}

	sum := sha256.Sum256(payload)
	totalChunks := max((len(payload)+chunkSize-1)/chunkSize, 1)
	chunks := make([]*proto.AgentConfigChunk, 0, totalChunks)

	for i := range totalChunks {
		end := min((i+1)*chunkSize, len(payload))
		chunks = append(chunks, &proto.AgentConfigChunk{
			ConfigVersion: resp.GetConfigVersion(),
			Payload:       payload[i*chunkSize : end],
			IsFinal:       i == totalChunks-1,
			ChunkIndex:    int32(i),
			TotalChunks:   int32(totalChunks),
			PayloadSha256: hex.EncodeToString(sum[:]),
		})
	}

	return chunks
}

func largeConfigResponse(version string) *proto.AgentConfigResponse {
	return &proto.AgentConfigResponse{
		ConfigVersion: version,
		ConfigJson:    bytes.Repeat([]byte(version), 300_000),
	}
}

func TestConfigPushAssemblerReturnsConfigOnlyOnFinalChunk(t *testing.T) {
	t.Parallel()

	want := largeConfigResponse("config-v2")
	chunks := pushedConfigChunks(t, want, 1024*1024)
	if len(chunks) < 3 {
		t.Fatalf("expected a multi-chunk push, got %d chunk(s)", len(chunks))
	}

	var assembler configPushAssembler
	for i, chunk := range chunks[:len(chunks)-1] {
		got, err := assembler.add(chunk)
		if err != nil || got != nil {
			t.Fatalf("chunk %d: got (%v, %v), want (nil, nil) before the final chunk", i, got, err)
		}
	}

	got, err := assembler.add(chunks[len(chunks)-1])
	if err != nil {
		t.Fatalf("final chunk: unexpected error %v", err)
	}
	if !goproto.Equal(got, want) {
		t.Fatal("reassembled pushed config does not match the pushed config")
	}
}

func TestConfigPushAssemblerDiscardsPartialPushWhenANewPushStarts(t *testing.T) {
	t.Parallel()

	abandoned := pushedConfigChunks(t, largeConfigResponse("config-old"), 1024*1024)
	want := largeConfigResponse("config-new")
	next := pushedConfigChunks(t, want, 1024*1024)

	var assembler configPushAssembler
	for _, chunk := range abandoned[:2] {
		if _, err := assembler.add(chunk); err != nil {
			t.Fatalf("abandoned push chunk: unexpected error %v", err)
		}
	}

	var got *proto.AgentConfigResponse
	for _, chunk := range next {
		var err error
		if got, err = assembler.add(chunk); err != nil {
			t.Fatalf("new push chunk %d: unexpected error %v", chunk.GetChunkIndex(), err)
		}
	}

	if !goproto.Equal(got, want) {
		t.Fatal("new push did not reassemble cleanly after an abandoned partial push")
	}
}

func TestConfigPushAssemblerRejectsMoreChunksThanThePushDeclares(t *testing.T) {
	t.Parallel()

	chunks := pushedConfigChunks(t, largeConfigResponse("config-v3"), 1024*1024)
	overflow := goproto.Clone(chunks[1]).(*proto.AgentConfigChunk)
	overflow.ChunkIndex = int32(len(chunks))

	var assembler configPushAssembler
	for _, chunk := range chunks[:len(chunks)-1] {
		if _, err := assembler.add(chunk); err != nil {
			t.Fatalf("unexpected error before overflow: %v", err)
		}
	}
	// The final chunk never arrives; one chunk too many must fail instead of
	// buffering without bound.
	if _, err := assembler.add(overflow); err != nil {
		t.Fatalf("unexpected error at the declared chunk count: %v", err)
	}

	got, err := assembler.add(overflow)
	if !errors.Is(err, agentgateway.ErrInvalidConfigStream) {
		t.Fatalf("add() = (%v, %v), want ErrInvalidConfigStream", got, err)
	}
	if len(assembler.chunks) != 0 {
		t.Fatalf("assembler kept %d chunks after rejecting the push", len(assembler.chunks))
	}
}

func TestConfigPushAssemblerRejectsTamperedPayload(t *testing.T) {
	t.Parallel()

	chunks := pushedConfigChunks(t, largeConfigResponse("config-v4"), 1024*1024)
	tampered := goproto.Clone(chunks[1]).(*proto.AgentConfigChunk)
	tampered.Payload = bytes.Repeat([]byte("x"), len(tampered.GetPayload()))
	chunks[1] = tampered

	var (
		assembler configPushAssembler
		got       *proto.AgentConfigResponse
		err       error
	)
	for _, chunk := range chunks {
		got, err = assembler.add(chunk)
	}

	if err == nil || got != nil {
		t.Fatalf("final add() = (%v, %v), want a checksum error and no config", got, err)
	}
}
