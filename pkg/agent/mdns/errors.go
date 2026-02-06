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

package mdns

import "errors"

var (
	// ErrListenAddrEmpty is returned when listen_addr is empty.
	ErrListenAddrEmpty = errors.New("listen_addr cannot be empty")
	// ErrMulticastGroupsEmpty is returned when multicast_groups is empty.
	ErrMulticastGroupsEmpty = errors.New("multicast_groups cannot be empty")
	// ErrDedupTTLZero is returned when dedup_ttl_secs is zero.
	ErrDedupTTLZero = errors.New("dedup_ttl_secs must be > 0")
	// ErrDedupMaxEntriesZero is returned when dedup_max_entries is zero.
	ErrDedupMaxEntriesZero = errors.New("dedup_max_entries must be > 0")
	// ErrDedupCleanupIntervalZero is returned when dedup_cleanup_interval_secs is zero.
	ErrDedupCleanupIntervalZero = errors.New("dedup_cleanup_interval_secs must be > 0")
)
