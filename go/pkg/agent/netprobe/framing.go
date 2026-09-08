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

package netprobe

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"google.golang.org/protobuf/proto"
)

const MaxFrameSize = 4 * 1024 * 1024

var ErrFrameTooLarge = errors.New("netprobe frame exceeds max size")

func readFrame(r io.Reader) (*netprobepb.NetprobeFrame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}

	size := binary.BigEndian.Uint32(lenBuf[:])
	if size > MaxFrameSize {
		return nil, fmt.Errorf("%w: %d", ErrFrameTooLarge, size)
	}

	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}

	var frame netprobepb.NetprobeFrame
	if err := proto.Unmarshal(body, &frame); err != nil {
		return nil, fmt.Errorf("decode netprobe frame: %w", err)
	}

	return &frame, nil
}

func writeFrame(w io.Writer, frame *netprobepb.NetprobeFrame) error {
	body, err := proto.Marshal(frame)
	if err != nil {
		return fmt.Errorf("encode netprobe frame: %w", err)
	}
	if len(body) > MaxFrameSize {
		return fmt.Errorf("%w: %d", ErrFrameTooLarge, len(body))
	}

	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(body)))
	if err := writeAll(w, lenBuf[:]); err != nil {
		return err
	}
	return writeAll(w, body)
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}

	return nil
}
