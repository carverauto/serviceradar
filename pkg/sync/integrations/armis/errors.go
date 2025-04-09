package armis

import "errors"

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
	errAuthFailed           = errors.New("authentication failed")
	errSearchRequestFailed  = errors.New("search request failed")
)
