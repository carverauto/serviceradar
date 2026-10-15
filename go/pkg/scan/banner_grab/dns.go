/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

// ProbeDNS asks a DNS server over TCP for its version.bind CHAOS TXT record.
func ProbeDNS(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	versionBindQuery := []byte{
		0x00, 0x21, 0x12, 0x34, 0x01, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'v',
		'e', 'r', 's', 'i', 'o', 'n', 0x04, 'b', 'i',
		'n', 'd', 0x00, 0x00, 0x10, 0x00, 0x03,
	}

	return probeTCP(ctx, host, port, ProtocolDNS, versionBindQuery, opts)
}
