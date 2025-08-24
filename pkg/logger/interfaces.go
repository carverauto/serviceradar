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

//go:generate mockgen -destination=mock_logger.go -package=logger github.com/carverauto/serviceradar/pkg/logger Logger,FieldLogger

package logger

import (
	"io"

	"github.com/rs/zerolog"
)

type Logger interface {
	Trace() *zerolog.Event
	Debug() *zerolog.Event
	Info() *zerolog.Event
	Warn() *zerolog.Event
	Error() *zerolog.Event
	Fatal() *zerolog.Event
	Panic() *zerolog.Event
	With() zerolog.Context
	WithComponent(component string) zerolog.Logger
	WithFields(fields map[string]interface{}) zerolog.Logger
	SetLevel(level zerolog.Level)
	SetDebug(debug bool)
}

type FieldLogger interface {
	WithField(key string, value interface{}) FieldLogger
	WithFields(fields map[string]interface{}) FieldLogger
	WithError(err error) FieldLogger
	Trace(msg string)
	Debug(msg string)
	Info(msg string)
	Warn(msg string)
	Error(msg string)
	Fatal(msg string)
	Panic(msg string)
}

type fieldLogger struct {
	logger zerolog.Logger
}

func NewFieldLogger(logger *zerolog.Logger) FieldLogger {
	return &fieldLogger{logger: *logger}
}

func (f *fieldLogger) WithField(key string, value interface{}) FieldLogger {
	return &fieldLogger{logger: f.logger.With().Interface(key, value).Logger()}
}

func (f *fieldLogger) WithFields(fields map[string]interface{}) FieldLogger {
	ctx := f.logger.With()
	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return &fieldLogger{logger: ctx.Logger()}
}

func (f *fieldLogger) WithError(err error) FieldLogger {
	return &fieldLogger{logger: f.logger.With().Err(err).Logger()}
}

func (f *fieldLogger) Trace(msg string) {
	f.logger.Trace().Msg(msg)
}

func (f *fieldLogger) Debug(msg string) {
	f.logger.Debug().Msg(msg)
}

func (f *fieldLogger) Info(msg string) {
	f.logger.Info().Msg(msg)
}

func (f *fieldLogger) Warn(msg string) {
	f.logger.Warn().Msg(msg)
}

func (f *fieldLogger) Error(msg string) {
	f.logger.Error().Msg(msg)
}

func (f *fieldLogger) Fatal(msg string) {
	f.logger.Fatal().Msg(msg)
}

func (f *fieldLogger) Panic(msg string) {
	f.logger.Panic().Msg(msg)
}

// NewTestLogger creates a no-op logger for testing that discards all output
func NewTestLogger() Logger {
	nopLogger := zerolog.New(io.Discard).Level(zerolog.Disabled)
	return &testLogger{nop: nopLogger}
}

// testLogger is a simple logger implementation for testing
type testLogger struct {
	nop zerolog.Logger
}

func (t *testLogger) Trace() *zerolog.Event { return t.nop.Trace() }
func (t *testLogger) Debug() *zerolog.Event { return t.nop.Debug() }
func (t *testLogger) Info() *zerolog.Event  { return t.nop.Info() }
func (t *testLogger) Warn() *zerolog.Event  { return t.nop.Warn() }
func (t *testLogger) Error() *zerolog.Event { return t.nop.Error() }
func (t *testLogger) Fatal() *zerolog.Event { return t.nop.Fatal() }
func (t *testLogger) Panic() *zerolog.Event { return t.nop.Panic() }
func (t *testLogger) With() zerolog.Context { return t.nop.With() }
func (t *testLogger) WithComponent(component string) zerolog.Logger {
	return t.nop.With().Str("component", component).Logger()
}
func (t *testLogger) WithFields(fields map[string]interface{}) zerolog.Logger {
	return t.nop.With().Fields(fields).Logger()
}
func (t *testLogger) SetLevel(level zerolog.Level) { t.nop = t.nop.Level(level) }
func (*testLogger) SetDebug(_ bool)                { /* no-op */ }
