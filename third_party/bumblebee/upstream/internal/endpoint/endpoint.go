// Package endpoint collects host identity used in every record.
package endpoint

import (
	"os"
	"os/user"
	"runtime"
	"strconv"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/model"
)

// Current returns the host identity used in every emitted record.
//
// deviceID, when non-empty, is set on Endpoint.DeviceID verbatim.
// Callers are expected to have already trimmed it and decided how to
// handle empty / whitespace input from the configured env var.
func Current(deviceID string) model.Endpoint {
	ep := model.Endpoint{
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		DeviceID: deviceID,
	}
	if h, err := os.Hostname(); err == nil {
		ep.Hostname = h
	}
	if u, err := user.Current(); err == nil {
		ep.Username = u.Username
		ep.UID = u.Uid
	} else {
		ep.UID = strconv.Itoa(os.Getuid())
	}
	return ep
}
