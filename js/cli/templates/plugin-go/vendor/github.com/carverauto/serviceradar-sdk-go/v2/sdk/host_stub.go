//go:build !tinygo

package sdk

func hostGetConfig(_ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostLog(_ uint32, _ uint32, _ uint32) {}

func hostSubmitResult(_ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostEmitTelemetry(_ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostArtifactOpen(_ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostArtifactWrite(_ uint32, _ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostArtifactCommit(_ uint32, _ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostArtifactAbort(_ uint32) int32 {
	return hostErrNotFound
}

func hostHTTPRequest(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostTCPConnect(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostTCPRead(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostTCPWrite(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostTCPClose(_ uint32) int32 {
	return hostErrNotFound
}

func hostUDPSendTo(_ uint32, _ uint32, _ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostWebSocketConnect(_ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostWebSocketSend(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostWebSocketRecv(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostWebSocketClose(_ uint32) int32 {
	return hostErrNotFound
}

func hostCameraMediaOpen(_ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostCameraMediaWrite(_ uint32, _ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostCameraMediaHeartbeat(_ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}

func hostCameraMediaClose(_ uint32, _ uint32, _ uint32) int32 {
	return hostErrNotFound
}
