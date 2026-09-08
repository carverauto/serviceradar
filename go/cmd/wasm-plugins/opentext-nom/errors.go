package main

type RunError struct {
	Code string
}

func (e RunError) Error() string {
	if e.Code == "" {
		return "opentext_nom_inventory_failed"
	}
	return e.Code
}

func runError(code string) error {
	return RunError{Code: code}
}

func safeErrorCode(err error) string {
	if typed, ok := err.(RunError); ok && typed.Code != "" {
		return typed.Code
	}
	return "opentext_nom_inventory_failed"
}
