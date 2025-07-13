/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package lifecycle

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/rs/zerolog"
)

// InitializeLogger initializes the logger with the provided configuration.
// If config is nil, it uses the default configuration.
func InitializeLogger(config *logger.Config) error {
	if config == nil {
		config = logger.DefaultConfig()
	}

	if err := logger.Init(config); err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	return nil
}

// LoggerImpl implements the logger.Logger interface without using global state
type LoggerImpl struct {
	logger zerolog.Logger
}

// NewLoggerImpl creates a new logger implementation
func NewLoggerImpl(config *logger.Config) (*LoggerImpl, error) {
	if config == nil {
		config = logger.DefaultConfig()
	}

	var output io.Writer = os.Stdout
	if config.Output == "stderr" {
		output = os.Stderr
	}

	level := zerolog.InfoLevel
	if config.Debug {
		level = zerolog.DebugLevel
	} else if config.Level != "" {
		var err error

		level, err = zerolog.ParseLevel(config.Level)
		if err != nil {
			return nil, err
		}
	}

	timeFormat := time.RFC3339
	if config.TimeFormat != "" {
		timeFormat = config.TimeFormat
	}

	if config.OTel.Enabled && config.OTel.Endpoint != "" {
		otelWriter, err := logger.NewOTELWriter(config.OTel)
		if err != nil {
			return nil, err
		}

		output = logger.NewMultiWriter(output, otelWriter)
	}

	zlog := zerolog.New(output).
		Level(level).
		With().
		Timestamp().
		Logger()

	// Set the time format
	zerolog.TimeFieldFormat = timeFormat

	return &LoggerImpl{logger: zlog}, nil
}

func (l *LoggerImpl) Debug() *zerolog.Event {
	return l.logger.Debug()
}

func (l *LoggerImpl) Info() *zerolog.Event {
	return l.logger.Info()
}

func (l *LoggerImpl) Warn() *zerolog.Event {
	return l.logger.Warn()
}

func (l *LoggerImpl) Error() *zerolog.Event {
	return l.logger.Error()
}

func (l *LoggerImpl) Fatal() *zerolog.Event {
	return l.logger.Fatal()
}

func (l *LoggerImpl) Panic() *zerolog.Event {
	return l.logger.Panic()
}

func (l *LoggerImpl) With() zerolog.Context {
	return l.logger.With()
}

func (l *LoggerImpl) WithComponent(component string) zerolog.Logger {
	return l.logger.With().Str("component", component).Logger()
}

func (l *LoggerImpl) WithFields(fields map[string]interface{}) zerolog.Logger {
	ctx := l.logger.With()
	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return ctx.Logger()
}

func (l *LoggerImpl) SetLevel(level zerolog.Level) {
	l.logger = l.logger.Level(level)
}

func (l *LoggerImpl) SetDebug(debug bool) {
	if debug {
		l.SetLevel(zerolog.DebugLevel)
	} else {
		l.SetLevel(zerolog.InfoLevel)
	}
}

// CreateLogger creates a new logger instance with the provided configuration.
// This returns a logger that can be injected into services.
func CreateLogger(config *logger.Config) (logger.Logger, error) {
	return NewLoggerImpl(config)
}

// CreateComponentLogger creates a logger for a specific component.
func CreateComponentLogger(component string, config *logger.Config) (logger.Logger, error) {
	loggerImpl, err := NewLoggerImpl(config)
	if err != nil {
		return nil, err
	}

	// Create a new logger with the component field
	componentLogger := &LoggerImpl{
		logger: loggerImpl.logger.With().Str("component", component).Logger(),
	}

	return componentLogger, nil
}

// ShutdownLogger shuts down the logger, flushing any pending logs.
func ShutdownLogger() error {
	return logger.Shutdown()
}
