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

package logger_test

import (
	"errors"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/logger"
)

func ExampleInit() {
	config := &logger.Config{
		Level:      "debug",
		Debug:      true,
		Output:     "stdout",
		TimeFormat: "",
	}

	err := logger.Init(config)
	if err != nil {
		panic(err)
	}

	logger.Info().Str("component", "example").Msg("Logger initialized successfully")
}

func ExampleInitWithDefaults() {
	err := logger.InitWithDefaults()
	if err != nil {
		panic(err)
	}

	logger.Info().Msg("Logger initialized with defaults")
}

func ExampleWithComponent() {
	componentLogger := logger.WithComponent("database")

	componentLogger.Info().
		Str("table", "users").
		Int("count", 150).
		Msg("Query executed successfully")
}

func ExampleWithFields() {
	fields := map[string]interface{}{
		"user_id":    12345,
		"session_id": "abc-123-def",
		"ip_address": "192.168.1.100",
	}

	enrichedLogger := logger.WithFields(fields)
	enrichedLogger.Info().Msg("User logged in")
}

func ExampleFieldLogger() {
	baseLogger := logger.GetLogger()
	fieldLogger := logger.NewFieldLogger(&baseLogger)

	userLogger := fieldLogger.WithField("user_id", 12345)
	userLogger.Info("User authenticated")

	err := errors.New("database connection failed")
	userLogger.WithError(err).Error("Failed to save user data")
}

func ExampleSetDebug() {
	logger.SetDebug(true)
	logger.Debug().Msg("This debug message will be visible")

	logger.SetDebug(false)
	logger.Debug().Msg("This debug message will be hidden")
	logger.Info().Msg("This info message will still be visible")
}

func Example_usageInService() {
	serviceLogger := logger.WithComponent("user-service")

	userID := 12345
	email := "user@example.com"

	serviceLogger.Info().
		Int("user_id", userID).
		Str("email", email).
		Msg("Processing user registration")

	if err := processUser(userID); err != nil {
		serviceLogger.Error().
			Err(err).
			Int("user_id", userID).
			Msg("Failed to process user")
	}

	serviceLogger.Info().
		Int("user_id", userID).
		Msg("User registration completed successfully")
}

func processUser(userID int) error {
	if userID <= 0 {
		return fmt.Errorf("invalid user ID: %d", userID)
	}

	return nil
}
