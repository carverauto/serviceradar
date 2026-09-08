package main

import "unsafe"

//go:wasmimport env get_config
func hostGetConfig(ptr, size uint32) int32

//go:wasmimport env camera_media_open
func hostCameraMediaOpen(reqPtr, reqLen uint32) int32

//go:wasmimport env camera_media_write
func hostCameraMediaWrite(handle, metaPtr, metaLen, payloadPtr, payloadLen uint32) int32

//go:wasmimport env camera_media_heartbeat
func hostCameraMediaHeartbeat(handle, metaPtr, metaLen uint32) int32

//go:wasmimport env camera_media_close
func hostCameraMediaClose(handle, reasonPtr, reasonLen uint32) int32

var (
	configBuf  = make([]byte, 1024)
	openReq    = []byte(`{"track_id":"video","codec":"h264","payload_format":"annexb"}`)
	heartbeat  = []byte(`{"sequence":1,"timestamp_unix":1735689600}`)
	chunkMeta  = []byte(`{"track_id":"video","sequence":1,"pts":1000,"dts":900,"keyframe":true,"codec":"h264","payload_format":"annexb"}`)
	chunkBytes = []byte{0x00, 0x00, 0x01, 0x09, 0x10}
	closeMsg   = []byte("stream complete")
)

func main() {}

//export stream_camera
func stream_camera() {
	_ = hostGetConfig(ptr(configBuf), uint32(len(configBuf)))

	handle := hostCameraMediaOpen(ptr(openReq), uint32(len(openReq)))
	if handle <= 0 {
		return
	}

	_ = hostCameraMediaHeartbeat(uint32(handle), ptr(heartbeat), uint32(len(heartbeat)))
	_ = hostCameraMediaWrite(
		uint32(handle),
		ptr(chunkMeta),
		uint32(len(chunkMeta)),
		ptr(chunkBytes),
		uint32(len(chunkBytes)),
	)
	_ = hostCameraMediaClose(uint32(handle), ptr(closeMsg), uint32(len(closeMsg)))
}

func ptr(buf []byte) uint32 {
	return uint32(uintptr(unsafe.Pointer(&buf[0])))
}
