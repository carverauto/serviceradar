package sdk

import "fmt"

const (
	hostErrOK        int32 = 0
	hostErrInvalid   int32 = -1
	hostErrDenied    int32 = -2
	hostErrTooLarge  int32 = -3
	hostErrNotFound  int32 = -4
	hostErrInternal  int32 = -5
	hostErrTimeout   int32 = -6
	hostErrBadHandle int32 = -7
)

// HostError represents an error returned by a host function.
type HostError struct {
	Code int32
	Op   string
}

func (e HostError) Error() string {
	if e.Op == "" {
		return fmt.Sprintf("host error %d", e.Code)
	}

	return fmt.Sprintf("host error %d (%s)", e.Code, e.Op)
}

func hostErr(code int32, op string) error {
	if code >= 0 {
		return nil
	}

	return HostError{Code: code, Op: op}
}
