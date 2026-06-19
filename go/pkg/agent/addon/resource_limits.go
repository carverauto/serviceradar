/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * You may not use this file except in compliance with the License.
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

package addon

import (
	"fmt"
	"path/filepath"
)

type resourceLimitStatus struct {
	Requested  bool
	Enforced   bool
	CgroupPath string
	Warning    string
}

func noResourceLimitCleanup() {}

func resourceLimitWarning(format string, args ...any) resourceLimitStatus {
	return resourceLimitStatus{
		Requested: true,
		Warning:   fmt.Sprintf(format, args...),
	}
}

func addonCgroupParent(root string, res Resources) string {
	if root == "" || res.Slice == "" {
		return root
	}

	cleanRoot := filepath.Clean(root)
	if filepath.Base(cleanRoot) == res.Slice {
		return cleanRoot
	}

	return filepath.Join(cleanRoot, res.Slice)
}
