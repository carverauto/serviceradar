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

package mapper

import (
	"fmt"
	"time"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) querySysInfoWithTimeout(
	client *gosnmp.GoSNMP, job *DiscoveryJob, target string, timeout time.Duration) (*DiscoveredDevice, error) {
	done := make(chan struct {
		device *DiscoveredDevice
		err    error
	}, 1)

	go func() {
		device, err := e.querySysInfo(client, target, job)

		done <- struct {
			device *DiscoveredDevice
			err    error
		}{device, err}
	}()

	select {
	case result := <-done:
		return result.device, result.err
	case <-time.After(timeout):
		return nil, fmt.Errorf("%w for %s", ErrSNMPQueryTimeout, target)
	}
}
