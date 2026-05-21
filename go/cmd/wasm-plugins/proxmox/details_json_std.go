//go:build !tinygo

package main

import "encoding/json"

func marshalProxmoxDetails(details proxmoxDetails) ([]byte, error) {
	return json.Marshal(details)
}
