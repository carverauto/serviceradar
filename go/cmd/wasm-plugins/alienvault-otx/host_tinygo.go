//go:build tinygo

package main

import (
	"fmt"
	"unsafe"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

//go:wasmimport env http_request
func hostHTTPRequest(reqPtr uint32, reqLen uint32, respPtr uint32, respLen uint32) int32

func doOTXHostHTTPRequest(apiURL, apiKey string, timeoutMS int) (*sdk.HTTPResponse, error) {
	request := []byte(otxHTTPRequestPayload(apiURL, apiKey, timeoutMS))
	response := make([]byte, 32*1024)

	result := hostHTTPRequest(bytesPtr(request), uint32(len(request)), bytesPtr(response), uint32(len(response)))
	if result < 0 {
		return nil, fmt.Errorf("host error %d (http_request)", result)
	}
	if result == 0 {
		return &sdk.HTTPResponse{}, nil
	}
	if uint32(result) > uint32(len(response)) {
		return nil, fmt.Errorf("host response too large (http_request)")
	}

	return decodeOTXHTTPResponse(response[:result])
}

func bytesPtr(value []byte) uint32 {
	if len(value) == 0 {
		return 0
	}

	return uint32(uintptr(unsafe.Pointer(&value[0])))
}
