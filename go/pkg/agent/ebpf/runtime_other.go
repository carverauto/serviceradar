//go:build !linux

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

package ebpf

import (
	"context"
	"fmt"
	"runtime"
)

func (r *Runtime) Check(context.Context) CapabilityReport {
	report := baseReport(runtime.GOOS + "/" + runtime.GOARCH)
	if r == nil {
		r = DefaultRuntime()
	}
	if !r.config.Enabled {
		report.AddReason(ReasonConfigDisabled)
		return report
	}
	report.AddReason(ReasonUnsupportedOS)
	return report
}

func (r *Runtime) LoadCollection(ctx context.Context, spec CollectionSpec) (Collection, error) {
	if err := spec.validate(); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if r == nil {
		r = DefaultRuntime()
	}
	if !r.config.Enabled {
		return nil, ErrRuntimeDisabled
	}
	report := r.Check(ctx)
	return nil, fmt.Errorf("%w: %s", ErrRuntimeUnavailable, report.Reasons[0])
}
