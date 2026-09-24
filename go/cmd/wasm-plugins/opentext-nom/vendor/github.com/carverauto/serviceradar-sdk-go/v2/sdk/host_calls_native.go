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

func callHostArtifactOpen(request []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.artifactOpen(request)
}

func callHostArtifactWrite(handle uint32, meta, payload []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.artifactWrite(handle, meta, payload)
}

func callHostArtifactCommit(handle uint32, request, response []byte) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.artifactCommit(handle, request, response)
}

func callHostArtifactAbort(handle uint32) int32 {
	host := currentLocalHost()
	if host == nil {
		return hostErrNotFound
	}
	return host.artifactAbort(handle)
}
