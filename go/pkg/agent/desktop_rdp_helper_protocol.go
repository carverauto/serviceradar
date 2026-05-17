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
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	desktopRDPHelperFrameHeaderSize = 5
	desktopRDPHelperMaxFrameBytes   = 16 * 1024 * 1024
	desktopRDPHelperMaxControlBytes = 512 * 1024

	desktopRDPHelperMessageOpen       desktopRDPHelperMessageType = 1
	desktopRDPHelperMessageInput      desktopRDPHelperMessageType = 2
	desktopRDPHelperMessageMediaFrame desktopRDPHelperMessageType = 3
	desktopRDPHelperMessageAck        desktopRDPHelperMessageType = 4
	desktopRDPHelperMessageClose      desktopRDPHelperMessageType = 5
	desktopRDPHelperMessageError      desktopRDPHelperMessageType = 6
)

var (
	errDesktopRDPHelperInvalidFrame  = errors.New("invalid desktop rdp helper frame")
	errDesktopRDPHelperFrameTooLarge = errors.New("desktop rdp helper frame too large")
)

type desktopRDPHelperMessageType byte

type desktopRDPHelperFrame struct {
	Type    desktopRDPHelperMessageType
	Payload []byte
}

func writeDesktopRDPHelperFrame(w io.Writer, frame desktopRDPHelperFrame) error {
	if w == nil {
		return fmt.Errorf("%w: missing writer", errDesktopRDPHelperInvalidFrame)
	}
	if err := validateDesktopRDPHelperFrame(frame, desktopRDPHelperMaxFrameBytes); err != nil {
		return err
	}

	var header [desktopRDPHelperFrameHeaderSize]byte
	binary.BigEndian.PutUint32(header[0:4], uint32(len(frame.Payload)+1))
	header[4] = byte(frame.Type)
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	if len(frame.Payload) == 0 {
		return nil
	}
	_, err := w.Write(frame.Payload)

	return err
}

func readDesktopRDPHelperFrame(r io.Reader, maxFrameBytes int) (desktopRDPHelperFrame, error) {
	if r == nil {
		return desktopRDPHelperFrame{}, fmt.Errorf("%w: missing reader", errDesktopRDPHelperInvalidFrame)
	}
	if maxFrameBytes <= 0 || maxFrameBytes > desktopRDPHelperMaxFrameBytes {
		maxFrameBytes = desktopRDPHelperMaxFrameBytes
	}

	var header [desktopRDPHelperFrameHeaderSize]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return desktopRDPHelperFrame{}, err
	}

	length := binary.BigEndian.Uint32(header[0:4])
	if length == 0 {
		return desktopRDPHelperFrame{}, fmt.Errorf("%w: missing message type", errDesktopRDPHelperInvalidFrame)
	}
	messageType := desktopRDPHelperMessageType(header[4])
	if err := validateDesktopRDPHelperMessageType(messageType); err != nil {
		return desktopRDPHelperFrame{}, err
	}
	if limit := maxDesktopRDPHelperFrameBytes(messageType, maxFrameBytes); length > uint32(limit) {
		return desktopRDPHelperFrame{}, fmt.Errorf("%w: %d", errDesktopRDPHelperFrameTooLarge, length)
	}

	frame := desktopRDPHelperFrame{
		Type:    messageType,
		Payload: make([]byte, int(length)-1),
	}
	if len(frame.Payload) == 0 {
		return frame, nil
	}
	if _, err := io.ReadFull(r, frame.Payload); err != nil {
		return desktopRDPHelperFrame{}, err
	}

	return frame, nil
}

func validateDesktopRDPHelperFrame(frame desktopRDPHelperFrame, maxFrameBytes int) error {
	if maxFrameBytes <= 0 || maxFrameBytes > desktopRDPHelperMaxFrameBytes {
		maxFrameBytes = desktopRDPHelperMaxFrameBytes
	}
	if err := validateDesktopRDPHelperMessageType(frame.Type); err != nil {
		return err
	}
	if len(frame.Payload)+1 > maxDesktopRDPHelperFrameBytes(frame.Type, maxFrameBytes) {
		return fmt.Errorf("%w: %d", errDesktopRDPHelperFrameTooLarge, len(frame.Payload)+1)
	}

	return nil
}

func maxDesktopRDPHelperFrameBytes(messageType desktopRDPHelperMessageType, maxFrameBytes int) int {
	if maxFrameBytes <= 0 || maxFrameBytes > desktopRDPHelperMaxFrameBytes {
		maxFrameBytes = desktopRDPHelperMaxFrameBytes
	}
	if messageType == desktopRDPHelperMessageMediaFrame {
		return maxFrameBytes
	}
	if maxFrameBytes < desktopRDPHelperMaxControlBytes {
		return maxFrameBytes
	}

	return desktopRDPHelperMaxControlBytes
}

func validateDesktopRDPHelperMessageType(messageType desktopRDPHelperMessageType) error {
	switch messageType {
	case desktopRDPHelperMessageOpen,
		desktopRDPHelperMessageInput,
		desktopRDPHelperMessageMediaFrame,
		desktopRDPHelperMessageAck,
		desktopRDPHelperMessageClose,
		desktopRDPHelperMessageError:
		return nil
	default:
		return fmt.Errorf("%w: unsupported helper message type", errDesktopRDPHelperInvalidFrame)
	}
}
