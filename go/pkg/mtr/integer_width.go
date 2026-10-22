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

package mtr

import (
	"errors"
	"fmt"
	"math"
)

// errIntegerWidth is returned when a value cannot be stored in the width the
// wire or a syscall field requires. Callers must fail the operation instead of
// truncating: a truncated BPF length or port would install a different program
// or bind a different port than the one requested.
var errIntegerWidth = errors.New("value does not fit in the destination width")

func uint16FromInt(v int) (uint16, error) {
	if v < 0 || v > math.MaxUint16 {
		return 0, fmt.Errorf("%w: %d as uint16", errIntegerWidth, v)
	}

	return uint16(v), nil
}

func int32FromInt(v int) (int32, error) {
	if v < math.MinInt32 || v > math.MaxInt32 {
		return 0, fmt.Errorf("%w: %d as int32", errIntegerWidth, v)
	}

	return int32(v), nil
}
