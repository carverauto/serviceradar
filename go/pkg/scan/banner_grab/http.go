/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

func ProbeHTTP(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	return probeTCP(ctx, host, port, ProtocolHTTP, []byte("HEAD / HTTP/1.1\r\nHost: "+host+"\r\nConnection: close\r\n\r\n"), opts)
}
