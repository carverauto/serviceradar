package sdk

import "fmt"

// Execute runs the plugin function and submits its result.
func Execute(fn func() (*Result, error)) error {
	result, err := fn()
	if err != nil {
		Log.Error("plugin error")
		if result == nil {
			result = Critical(fmt.Sprintf("plugin error: %v", err))
		} else {
			result.Status = StatusCritical
			if result.Summary == "" {
				result.Summary = fmt.Sprintf("plugin error: %v", err)
			}

			if result.Details == "" {
				result.Details = err.Error()
			}
		}
	}

	if result == nil {
		result = NewResult()
	}

	result.finalize()

	payload, err := result.Serialize()
	if err != nil {
		Log.Error("failed to serialize result")
		return err
	}

	if err := SubmitResult(payload); err != nil {
		Log.Error("failed to submit result")
		return err
	}

	return nil
}

// SubmitResult sends a serialized result payload to the host.
func SubmitResult(payload []byte) error {
	if len(payload) == 0 {
		return HostError{Code: hostErrInvalid, Op: "submit_result"}
	}
	res := callHostSubmitResult(payload)

	return hostErr(res, "submit_result")
}
