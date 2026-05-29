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

package banner_grab

// Batcher groups observations by max count and approximate payload bytes.
type Batcher struct {
	maxCount int
	maxBytes int
	current  []BannerObservation
	bytes    int
}

func NewBatcher(maxCount, maxBytes int) *Batcher {
	if maxCount <= 0 {
		maxCount = 256
	}
	if maxBytes <= 0 {
		maxBytes = 1024 * 1024
	}

	return &Batcher{
		maxCount: maxCount,
		maxBytes: maxBytes,
		current:  make([]BannerObservation, 0, maxCount),
	}
}

func (b *Batcher) Add(observation BannerObservation) ([]BannerObservation, bool) {
	size := observationSize(observation)
	if len(b.current) > 0 && b.bytes+size > b.maxBytes {
		return b.flushWithNext(observation, size), true
	}

	b.current = append(b.current, observation)
	b.bytes += size

	if len(b.current) >= b.maxCount {
		return b.Flush(), true
	}

	return nil, false
}

func (b *Batcher) Flush() []BannerObservation {
	if len(b.current) == 0 {
		return nil
	}

	out := append([]BannerObservation(nil), b.current...)
	b.current = b.current[:0]
	b.bytes = 0

	return out
}

func (b *Batcher) flushWithNext(observation BannerObservation, size int) []BannerObservation {
	out := b.Flush()
	b.current = append(b.current, observation)
	b.bytes = size

	return out
}

func observationSize(observation BannerObservation) int {
	return len(observation.Host) + len(observation.Protocol) + len(observation.Source) + len(observation.BannerBytes) + 32
}
