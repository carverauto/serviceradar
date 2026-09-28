package sdk

// Logger forwards messages to the host logger.
type Logger struct{}

// Log is the default logger instance.
//
//nolint:gochecknoglobals
var Log Logger

func (Logger) Debug(msg string) { logWithLevel(0, msg) }
func (Logger) Info(msg string)  { logWithLevel(1, msg) }
func (Logger) Warn(msg string)  { logWithLevel(2, msg) }
func (Logger) Error(msg string) { logWithLevel(3, msg) }

func logWithLevel(level uint32, msg string) {
	if msg == "" {
		return
	}
	data := []byte(msg)
	callHostLog(level, data)
}
