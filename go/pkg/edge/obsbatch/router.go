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

package obsbatch

import (
	"strconv"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Router groups incoming hosts into batches by their exact attempted-check
// dictionary. Hosts whose dictionaries differ (including order, because open
// ports reference a check by index) never share a batch; each distinct
// dictionary gets its own Builder. This enforces the design rule that every
// host in one batch shares the exact tested-check set.
//
// Not safe for concurrent use; drive from a single goroutine.
type Router struct {
	base   Context // TestedChecks is ignored; each builder supplies its own
	limits Limits
	seq    *sequencer // one contiguous batch-sequence space shared by all builders

	builders map[string]*Builder
	order    []string // active dictionaries, least-recently-used at the front
}

// NewRouter creates a Router. The base context supplies every batch-level field
// except the per-dictionary TestedChecks, which are provided per Add call. Every
// dictionary's builder shares one batch-sequence space so a terminal can prove a
// single contiguous [1,N] interval across the whole attempt.
func NewRouter(base Context, limits Limits) *Router {
	return &Router{
		base:     base,
		limits:   limits.withDefaults(),
		seq:      &sequencer{},
		builders: make(map[string]*Builder),
	}
}

// Add routes a host to the Builder for its dictionary, creating one on first
// sight, and returns any batches completed by this call. When admitting a new
// dictionary would exceed the active-dictionary bound, the least-recently-used
// open builder is flushed and evicted first so retained state stays bounded
// regardless of how many distinct dictionaries a plan produces.
func (r *Router) Add(testedChecks []*edgev1.SweepTestV1, host *edgev1.SweepHostObservationV1) ([]*edgev1.SweepObservationBatchV1, error) {
	key := dictKey(testedChecks)

	var flushed []*edgev1.SweepObservationBatchV1
	b := r.builders[key]
	if b == nil {
		flushed = append(flushed, r.evictToFit()...)
		ctx := r.base
		ctx.TestedChecks = testedChecks
		b = newBuilder(ctx, r.limits, r.seq)
		r.builders[key] = b
		r.order = append(r.order, key)
	} else {
		r.touch(key)
	}

	batches, err := b.Add(host)
	flushed = append(flushed, batches...)
	return flushed, err
}

// evictToFit flushes and removes least-recently-used builders until adding one
// more dictionary stays within MaxActiveDicts.
func (r *Router) evictToFit() []*edgev1.SweepObservationBatchV1 {
	var out []*edgev1.SweepObservationBatchV1
	for len(r.builders) >= r.limits.MaxActiveDicts && len(r.order) > 0 {
		victim := r.order[0]
		r.order = r.order[1:]
		if b := r.builders[victim]; b != nil {
			if batch := b.Flush(); batch != nil {
				out = append(out, batch)
			}
			delete(r.builders, victim)
		}
	}
	return out
}

// touch moves a dictionary to the most-recently-used end of the ring.
func (r *Router) touch(key string) {
	for i, k := range r.order {
		if k == key {
			r.order = append(r.order[:i], r.order[i+1:]...)
			r.order = append(r.order, key)
			return
		}
	}
}

// Flush flushes every open builder in first-seen order and returns the
// resulting batches.
func (r *Router) Flush() []*edgev1.SweepObservationBatchV1 {
	var out []*edgev1.SweepObservationBatchV1
	for _, key := range r.order {
		if batch := r.builders[key].Flush(); batch != nil {
			out = append(out, batch)
		}
	}
	return out
}

// ActiveDicts reports how many dictionaries currently have an open builder.
func (r *Router) ActiveDicts() int { return len(r.builders) }

// dictKey is a stable, order-sensitive key for an attempted-check dictionary.
func dictKey(checks []*edgev1.SweepTestV1) string {
	var sb strings.Builder
	for _, c := range checks {
		sb.WriteString(strconv.Itoa(int(c.GetMode())))
		sb.WriteByte(':')
		sb.WriteString(strconv.Itoa(int(c.GetProtocol())))
		sb.WriteByte(':')
		sb.WriteString(strconv.Itoa(int(c.GetPort())))
		sb.WriteByte(';')
	}
	return sb.String()
}
