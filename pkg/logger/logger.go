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
	"io"
	"os"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

var globalLogger zerolog.Logger

type Config struct {
	Level      string `json:"level" yaml:"level"`
	Debug      bool   `json:"debug" yaml:"debug"`
	Output     string `json:"output" yaml:"output"`
	TimeFormat string `json:"time_format" yaml:"time_format"`
}

func init() {
	globalLogger = zerolog.New(os.Stdout).With().Timestamp().Logger()
	zerolog.TimeFieldFormat = time.RFC3339
}

func Init(config Config) error {
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

	globalLogger = zerolog.New(output).
		Level(level).
		With().
		Timestamp().
		Logger()

	log.Logger = globalLogger

	return nil
}

func SetLevel(level zerolog.Level) {
	globalLogger = globalLogger.Level(level)
	log.Logger = globalLogger
}

func SetDebug(debug bool) {
	if debug {
		SetLevel(zerolog.DebugLevel)
	} else {
		SetLevel(zerolog.InfoLevel)
	}
}

func GetLogger() zerolog.Logger {
	return globalLogger
}

func Debug() *zerolog.Event {
	return globalLogger.Debug()
}

func Info() *zerolog.Event {
	return globalLogger.Info()
}

func Warn() *zerolog.Event {
	return globalLogger.Warn()
}

func Error() *zerolog.Event {
	return globalLogger.Error()
}

func Fatal() *zerolog.Event {
	return globalLogger.Fatal()
}

func Panic() *zerolog.Event {
	return globalLogger.Panic()
}

func With() zerolog.Context {
	return globalLogger.With()
}

func WithComponent(component string) zerolog.Logger {
	return globalLogger.With().Str("component", component).Logger()
}

func WithFields(fields map[string]interface{}) zerolog.Logger {
	ctx := globalLogger.With()
	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return ctx.Logger()
}
