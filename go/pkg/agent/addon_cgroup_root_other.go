// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

//go:build !linux

package agent

func defaultAddonCgroupRoot() (string, error) {
	return "", nil
}
