/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

//nolint:gochecknoglobals // packet template constant
var rdpX224ConnectionRequest = []byte{
	0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x03,
	0x00, 0x00, 0x00,
}

func ProbeRDP(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	return probeTCP(ctx, host, port, ProtocolRDP, rdpX224ConnectionRequest, opts)
}
