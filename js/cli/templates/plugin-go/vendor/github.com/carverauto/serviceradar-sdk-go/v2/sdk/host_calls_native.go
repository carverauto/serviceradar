//go:build !tinygo

package sdk

func callHostGetConfig(buf []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.getConfig(buf)
}

func callHostLog(level uint32, data []byte) {
	host := currentLocalHost()
	if host != nil {
		host.log(level, data)
	}
}

func callHostSubmitResult(payload []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.submitResult(payload)
}

func callHostEmitTelemetry(payload []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.emitTelemetry(payload)
}

func callHostHTTPRequest(request, response []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.httpRequest(request, response)
}
