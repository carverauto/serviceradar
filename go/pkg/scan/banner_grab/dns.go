/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

//nolint:gochecknoglobals // packet template constant
var dnsVersionBindQueryTCP = []byte{
	0x00, 0x21, 0x12, 0x34, 0x01, 0x00, 0x00, 0x01,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'v',
	'e', 'r', 's', 'i', 'o', 'n', 0x04, 'b', 'i',
	'n', 'd', 0x00, 0x00, 0x10, 0x00, 0x03,
}

func ProbeDNS(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	return probeTCP(ctx, host, port, ProtocolDNS, dnsVersionBindQueryTCP, opts)
}
