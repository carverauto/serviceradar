//go:build tinygo

package sdk

//go:wasmimport env get_config
func hostGetConfig(ptr uint32, size uint32) int32

//go:wasmimport env log
func hostLog(level uint32, ptr uint32, size uint32)

//go:wasmimport env submit_result
func hostSubmitResult(ptr uint32, size uint32) int32

//go:wasmimport env emit_telemetry
func hostEmitTelemetry(ptr uint32, size uint32) int32

//go:wasmimport env artifact_open
func hostArtifactOpen(reqPtr uint32, reqLen uint32) int32

//go:wasmimport env artifact_write
func hostArtifactWrite(handle uint32, metaPtr uint32, metaLen uint32, payloadPtr uint32, payloadLen uint32) int32

//go:wasmimport env artifact_commit
func hostArtifactCommit(handle uint32, reqPtr uint32, reqLen uint32, respPtr uint32, respLen uint32) int32

//go:wasmimport env artifact_abort
func hostArtifactAbort(handle uint32) int32

//go:wasmimport env http_request
func hostHTTPRequest(reqPtr uint32, reqLen uint32, respPtr uint32, respLen uint32) int32

//go:wasmimport env tcp_connect
func hostTCPConnect(addrPtr uint32, addrLen uint32, port uint32, timeoutMS uint32) int32

//go:wasmimport env tcp_read
func hostTCPRead(handle uint32, bufPtr uint32, bufLen uint32, timeoutMS uint32) int32

//go:wasmimport env tcp_write
func hostTCPWrite(handle uint32, bufPtr uint32, bufLen uint32, timeoutMS uint32) int32

//go:wasmimport env tcp_close
func hostTCPClose(handle uint32) int32

//go:wasmimport env udp_sendto
func hostUDPSendTo(addrPtr uint32, addrLen uint32, port uint32, bufPtr uint32, bufLen uint32, timeoutMS uint32) int32

//go:wasmimport env websocket_connect
func hostWebSocketConnect(urlPtr uint32, urlLen uint32, timeoutMS uint32) int32

//go:wasmimport env websocket_send
func hostWebSocketSend(handle uint32, dataPtr uint32, dataLen uint32, timeoutMS uint32) int32

//go:wasmimport env websocket_recv
func hostWebSocketRecv(handle uint32, bufPtr uint32, bufLen uint32, timeoutMS uint32) int32

//go:wasmimport env websocket_close
func hostWebSocketClose(handle uint32) int32

//go:wasmimport env camera_media_open
func hostCameraMediaOpen(reqPtr uint32, reqLen uint32) int32

//go:wasmimport env camera_media_write
func hostCameraMediaWrite(handle uint32, metaPtr uint32, metaLen uint32, payloadPtr uint32, payloadLen uint32) int32

//go:wasmimport env camera_media_heartbeat
func hostCameraMediaHeartbeat(handle uint32, metaPtr uint32, metaLen uint32) int32

//go:wasmimport env camera_media_close
func hostCameraMediaClose(handle uint32, reasonPtr uint32, reasonLen uint32) int32
