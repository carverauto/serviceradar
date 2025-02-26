package config

// Validator interface for configurations that need validation.
type Validator interface {
	Validate() error
}
