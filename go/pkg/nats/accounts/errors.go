package accounts

import "errors"

var (
	ErrSubjectOutOfScope       = errors.New("subject outside approved account scope")
	ErrImportNotAllowed        = errors.New("stream imports are not allowed")
	ErrJetStreamLimitUnbounded = errors.New("jetstream limits must be finite")
)
