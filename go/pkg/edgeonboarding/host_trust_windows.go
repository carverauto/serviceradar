//go:build windows

package edgeonboarding

import "errors"

var errPrivilegedHostTrustRequiresUnix = errors.New("privileged host trust requires a unix host")

func establishPrivilegedHostTrust(string) error {
	return errPrivilegedHostTrustRequiresUnix
}
