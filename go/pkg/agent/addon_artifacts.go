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

package agent

import (
	"context"
	"strings"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
)

func (s *Server) handleAddonArtifact(ctx context.Context, artifact agentaddon.ArtifactSubmission) error {
	if s == nil {
		return errPluginArtifactUploaderUnavailable
	}

	s.mu.RLock()
	uploader := s.artifactUploader
	s.mu.RUnlock()

	if uploader == nil {
		return errPluginArtifactUploaderUnavailable
	}

	assignmentID := strings.TrimSpace(artifact.AssignmentID)
	if assignmentID == "" {
		assignmentID = artifact.AddonID
	}

	response, err := uploader.UploadPluginArtifact(ctx, PluginArtifactUploadRequest{
		AssignmentID: assignmentID,
		PluginID:     artifact.AddonID,
		PluginName:   artifact.AddonID,
		Source:       "native-addon",
		DownloadURL:  artifact.DownloadURL,
		ObjectKey:    artifact.ObjectKey,
		ContentType:  artifact.ContentType,
		SHA256:       artifact.SHA256,
		Size:         artifact.Size,
		FilePath:     artifact.FilePath,
		Attributes:   artifact.Attributes,
	})
	if err != nil {
		return err
	}
	if response.ObjectKey == "" {
		return errPluginArtifactUploaderUnavailable
	}

	return nil
}
