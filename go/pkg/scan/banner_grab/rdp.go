/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

// ProbeRDP sends an X.224 connection request.
func ProbeRDP(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	x224ConnectionRequest := []byte{
		0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x03,
		0x00, 0x00, 0x00,
	}

	return probeTCP(ctx, host, port, ProtocolRDP, x224ConnectionRequest, opts)
}
