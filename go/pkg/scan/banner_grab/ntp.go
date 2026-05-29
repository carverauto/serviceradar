/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

//nolint:gochecknoglobals // packet template constant
var ntpReadvarRequest = []byte{0x17, 0x02, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x00}

func ProbeNTP(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	return probeUDP(ctx, host, port, ProtocolNTP, ntpReadvarRequest, opts)
}
