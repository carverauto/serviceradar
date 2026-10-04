package main

import (
	"errors"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// The host returns only a numeric code for a refused or failed request; the
// reason stays in the agent's log. These hints turn the code an operator sees
// into the place to look, so "host error -5" does not read like a plugin bug.
const (
	hintHostDenied = "refused by the agent's host policy (credential binding, egress rule, or an expired " +
		"credential grant); the agent log line \"Plugin host HTTP request denied\" names the reason"
	hintHostInternal = "connection or TLS failure; the PVE certificate must list this target address in its " +
		"SANs and chain to the pinned CA (agent log line \"Plugin host HTTP request failed\")"
	hintHostTimeout = "request timed out"
	hintAuth        = "authentication failed: the API token must be user@realm!token=secret for an existing token"
	hintForbidden   = "permission denied: the token needs an ACL granting Sys.Audit and VM.Audit on /"
)

const (
	hostErrDenied   int32 = -2
	hostErrInternal int32 = -5
	hostErrTimeout  int32 = -6
)

// describeTargetError is the redacted error text plus the action it calls for.
func describeTargetError(err error) string {
	if err == nil {
		return ""
	}

	msg := sanitizeError(err)
	if hint := targetErrorHint(err, msg); hint != "" {
		return msg + ": " + hint
	}

	return msg
}

func targetErrorHint(err error, msg string) string {
	var hostErr sdk.HostError
	if errors.As(err, &hostErr) {
		if hint := hostErrorHint(hostErr.Code); hint != "" {
			return hint
		}
	}

	switch {
	case strings.Contains(msg, "host error -2"):
		return hintHostDenied
	case strings.Contains(msg, "host error -5"):
		return hintHostInternal
	case strings.Contains(msg, "host error -6"):
		return hintHostTimeout
	case strings.Contains(msg, "HTTP 401"):
		return hintAuth
	case strings.Contains(msg, "HTTP 403"):
		return hintForbidden
	default:
		return ""
	}
}

func hostErrorHint(code int32) string {
	switch code {
	case hostErrDenied:
		return hintHostDenied
	case hostErrInternal:
		return hintHostInternal
	case hostErrTimeout:
		return hintHostTimeout
	default:
		return ""
	}
}
