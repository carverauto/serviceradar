// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

package agent

import "context"

// startManagedLocalNATS starts at most one managed local NATS supervisor loop
// when the platform has a managed local NATS binding configured.
func (p *PushLoop) startManagedLocalNATS(ctx context.Context) {
	if !managedLocalNATSConfigured() {
		return
	}
	if !p.managedLocalNATSRunning.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer p.managedLocalNATSRunning.Store(false)
		p.managedLocalNATSLoop(ctx)
	}()
}
