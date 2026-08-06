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

package k8sinventory

import "errors"

// Precondition failures shared across this package. Config, publisher and spool errors stay
// next to the code that owns them (config.go, publisher.go, spool.go); these are here because
// more than one file returns them, and duplicating a sentinel would defeat errors.Is.
var (
	errControllerNil         = errors.New("controller is nil")
	errListerNil             = errors.New("lister is nil")
	errPublisherNil          = errors.New("publisher is nil")
	errRuntimeNotInitialized = errors.New("runtime not initialized")
	errKubeClientNil         = errors.New("kubernetes client is nil")
	errInformerSyncTimeout   = errors.New("timed out waiting for service/endpointslice informer sync")
	errNilGateway            = errors.New("nil gateway object")
	errNilRoute              = errors.New("nil route object")
)
