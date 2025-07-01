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

package grpc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	certManagerPerms = 0700
)

var (
	errMissingCerts = fmt.Errorf("missing certificates")
)

// CertificateManager helps manage TLS certificates.
type CertificateManager struct {
	config *models.SecurityConfig
}

func NewCertificateManager(config *models.SecurityConfig) *CertificateManager {
	return &CertificateManager{config: config}
}

func (cm *CertificateManager) EnsureCertificateDirectory() error {
	return os.MkdirAll(cm.config.CertDir, certManagerPerms)
}

func (cm *CertificateManager) ValidateCertificates(mutual bool) error {
	required := []string{"ca.crt", "server.crt", "server.key"}
	if mutual {
		required = append(required, "client.crt", "client.key")
	}

	var missing []string

	for _, file := range required {
		path := filepath.Join(cm.config.CertDir, file)

		if _, err := os.Stat(path); os.IsNotExist(err) {
			missing = append(missing, file)
		}
	}

	if len(missing) > 0 {
		return fmt.Errorf("%w %s", errMissingCerts, strings.Join(missing, ", "))
	}

	return nil
}
