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

package integrations

import (
	"context"
	"log"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/models"
)

type ArmisIntegration struct {
	config models.SourceConfig
}

func NewArmisIntegration(_ context.Context, config models.SourceConfig) *ArmisIntegration {
	return &ArmisIntegration{config: config}
}

func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.config.Endpoint, http.NoBody)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+a.config.Credentials["api_key"])

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.Printf("Failed to close response body: %v", err)
		}
	}()

	data := make(map[string][]byte)
	data["devices"] = []byte("mock_armis_data") // Replace with real parsing

	return data, nil
}
