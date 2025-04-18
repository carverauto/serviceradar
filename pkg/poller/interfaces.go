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

package poller

//go:generate mockgen -destination=mock_poller.go -package=poller github.com/carverauto/serviceradar/pkg/poller Clock,Ticker

import "time"

// Clock abstracts time-related operations.
type Clock interface {
	Now() time.Time
	Ticker(d time.Duration) Ticker
}

// Ticker abstracts the ticker behavior.
type Ticker interface {
	Chan() <-chan time.Time
	Stop()
}
