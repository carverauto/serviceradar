//go:build !tinygo

package main

func hostProxmoxConsoleOpen(_ uint32, _ uint32) int32 {
	return -4
}

func hostProxmoxConsoleWrite(_ uint32, _ uint32, _ uint32) int32 {
	return -4
}

func hostProxmoxConsoleRead(_ uint32, _ uint32, _ uint32, _ uint32) int32 {
	return -4
}

func hostProxmoxConsoleClose(_ uint32, _ uint32, _ uint32) int32 {
	return -4
}

func hostProxmoxConsoleSSHConnect(_ uint32, _ uint32) int32 {
	return -4
}
