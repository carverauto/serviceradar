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

package api

//go:generate mockgen -destination=mock_api_server.go -package=api github.com/carverauto/serviceradar/pkg/cloud/api Service

// Service represents the API server functionality.
type Service interface {
	Start(addr string) error
	UpdateNodeStatus(nodeID string, status *NodeStatus)
	SetNodeHistoryHandler(handler func(nodeID string) ([]NodeHistoryPoint, error))
	SetKnownPollers(knownPollers []string)
}
