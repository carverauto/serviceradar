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

func callHostArtifactOpen(request []byte) int32 {
	return hostArtifactOpen(ptrFromBytes(request), uint32(len(request)))
}

func callHostArtifactWrite(handle uint32, meta, payload []byte) int32 {
	return hostArtifactWrite(
		handle,
		ptrFromBytes(meta),
		uint32(len(meta)),
		ptrFromBytes(payload),
		uint32(len(payload)),
	)
}

func callHostArtifactCommit(handle uint32, request, response []byte) int32 {
	return hostArtifactCommit(
		handle,
		ptrFromBytes(request),
		uint32(len(request)),
		ptrFromBytes(response),
		uint32(len(response)),
	)
}

func callHostArtifactAbort(handle uint32) int32 {
	return hostArtifactAbort(handle)
}
