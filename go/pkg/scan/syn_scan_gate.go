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

package scan

// SYNScanGate admits one raw SYN scan at a time.
//
// Every SYNScanner on a host captures replies for the same source-port range,
// so two scans running together each receive the other's replies. That doubles
// the capture load, and sweep groups that start on the same schedule tick
// pushed the rings into kernel drops. Scanners that share a gate wait for the
// scan ahead of them instead, keeping their full port window and send rate.
//
// The owner of the scanners creates one gate and hands it to every scanner it
// builds through SYNScannerOptions.Gate.
type SYNScanGate struct {
	slot chan struct{}
}

// NewSYNScanGate returns a free gate.
func NewSYNScanGate() *SYNScanGate {
	return &SYNScanGate{slot: make(chan struct{}, 1)}
}
