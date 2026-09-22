//go:build tinygo

package sdk

func callHostGetConfig(buf []byte) int32 {
	return hostGetConfig(ptrFromBytes(buf), uint32(len(buf)))
}

func callHostLog(level uint32, data []byte) {
	hostLog(level, ptrFromBytes(data), uint32(len(data)))
}

func callHostSubmitResult(payload []byte) int32 {
	return hostSubmitResult(ptrFromBytes(payload), uint32(len(payload)))
}

func callHostEmitTelemetry(payload []byte) int32 {
	return hostEmitTelemetry(ptrFromBytes(payload), uint32(len(payload)))
}

func callHostHTTPRequest(request, response []byte) int32 {
	return hostHTTPRequest(
		ptrFromBytes(request),
		uint32(len(request)),
		ptrFromBytes(response),
		uint32(len(response)),
	)
}
