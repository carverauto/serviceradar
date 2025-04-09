package armis

import "errors"

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
	errAuthFailed           = errors.New("authentication failed")
	errSearchRequestFailed  = errors.New("search request failed")
	errNetworkError         = errors.New("network error")      // Added from lines 329 and 569
	errKVWriteError         = errors.New("KV write error")     // Added from line 350
	errConnectionRefused    = errors.New("connection refused") // Added from line 496
)
