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

// Package logger provides JSON structured logging using zerolog
package logger

import (
	"context"
	"io"
	"os"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

// LoggerInstance holds the global logger state
type LoggerInstance struct {
	logger     zerolog.Logger
	otelWriter *OTelWriter
}

// instance is the singleton logger instance
//
//nolint:gochecknoglobals // singleton pattern for logger state
var instance *LoggerInstance

type Config struct {
	Level      string     `json:"level" yaml:"level"`
	Debug      bool       `json:"debug" yaml:"debug"`
	Output     string     `json:"output" yaml:"output"`
	TimeFormat string     `json:"time_format" yaml:"time_format"`
	OTel       OTelConfig `json:"otel" yaml:"otel"`
}

// initDefaults initializes the default logger instance
func initDefaults() {
	if instance == nil {
		zerolog.TimeFieldFormat = time.RFC3339
		instance = &LoggerInstance{
			logger: zerolog.New(os.Stdout).With().Timestamp().Logger(),
		}
	}
}

func Init(ctx context.Context, config *Config) error {
	initDefaults()

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
			return err
		}
	}

	if config.TimeFormat != "" {
		zerolog.TimeFieldFormat = config.TimeFormat
	}

	if config.OTel.Enabled && config.OTel.Endpoint != "" {
		otelWriter, err := NewOTELWriter(ctx, config.OTel)
		if err != nil {
			return err
		}

		instance.otelWriter = otelWriter
		output = NewMultiWriter(output, otelWriter)
	}

	instance.logger = zerolog.New(output).
		Level(level).
		With().
		Timestamp().
		Logger()

	log.Logger = instance.logger

	return nil
}

func SetLevel(level zerolog.Level) {
	initDefaults()

	instance.logger = instance.logger.Level(level)
	log.Logger = instance.logger
}

func SetDebug(debug bool) {
	if debug {
		SetLevel(zerolog.DebugLevel)
	} else {
		SetLevel(zerolog.InfoLevel)
	}
}

func GetLogger() zerolog.Logger {
	initDefaults()
	return instance.logger
}

func Trace() *zerolog.Event {
	initDefaults()
	return instance.logger.Trace()
}

func Debug() *zerolog.Event {
	initDefaults()
	return instance.logger.Debug()
}

func Info() *zerolog.Event {
	initDefaults()
	return instance.logger.Info()
}

func Warn() *zerolog.Event {
	initDefaults()
	return instance.logger.Warn()
}

func Error() *zerolog.Event {
	initDefaults()
	return instance.logger.Error()
}

func Fatal() *zerolog.Event {
	initDefaults()
	return instance.logger.Fatal()
}

func Panic() *zerolog.Event {
	initDefaults()
	return instance.logger.Panic()
}

func With() zerolog.Context {
	initDefaults()
	return instance.logger.With()
}

func WithComponent(component string) zerolog.Logger {
	initDefaults()
	return instance.logger.With().Str("component", component).Logger()
}

func WithFields(fields map[string]interface{}) zerolog.Logger {
	initDefaults()

	ctx := instance.logger.With()

	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return ctx.Logger()
}

func Shutdown() error {
	return ShutdownOTEL()
}
