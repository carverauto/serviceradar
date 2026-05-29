/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import "context"

func ProbeTelnet(ctx context.Context, host string, port int, opts ProbeOpts) (BannerObservation, error) {
	return probeTCP(ctx, host, port, ProtocolTelnet, nil, opts)
}
