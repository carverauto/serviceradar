//go:build tinygo

package main

//go:wasmimport env proxmox_console_open
func hostProxmoxConsoleOpen(reqPtr uint32, reqLen uint32) int32

//go:wasmimport env proxmox_console_write
func hostProxmoxConsoleWrite(handle uint32, payloadPtr uint32, payloadLen uint32) int32

//go:wasmimport env proxmox_console_read
func hostProxmoxConsoleRead(handle uint32, bufPtr uint32, bufLen uint32, timeoutMS uint32) int32

//go:wasmimport env proxmox_console_close
func hostProxmoxConsoleClose(handle uint32, reasonPtr uint32, reasonLen uint32) int32

//go:wasmimport env proxmox_console_ssh_connect
func hostProxmoxConsoleSSHConnect(configPtr uint32, configLen uint32) int32
