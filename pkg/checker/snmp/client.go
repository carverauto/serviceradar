/*-
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

// Package snmp pkg/checker/snmp/client.go

package snmp

import (
	"fmt"
	"sync"
	"time"

	"github.com/gosnmp/gosnmp"
)

// SNMPClientImpl implements the SNMPClient interface using gosnmp.
type SNMPClientImpl struct {
	client     *gosnmp.GoSNMP
	target     *Target
	mu         sync.RWMutex
	connected  bool
	lastError  error
	reconnects int
}

// SNMPError wraps SNMP-specific errors with additional context.
type SNMPError struct {
	Op      string
	Target  string
	Wrapped error
}

func (e *SNMPError) Error() string {
	return fmt.Sprintf("SNMP %s failed for target %s: %v", e.Op, e.Target, e.Wrapped)
}

func newSNMPClient(target *Target) (SNMPClient, error) {
	if err := validateTarget(target); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrInvalidTargetConfig, err)
	}

	client := &gosnmp.GoSNMP{
		Target:             target.Host,
		Port:               target.Port,
		Community:          target.Community,
		Timeout:            time.Duration(target.Timeout),
		Retries:            target.Retries,
		ExponentialTimeout: true,
		MaxOids:            gosnmp.MaxOids,
	}

	// Set SNMP version based on configuration
	switch target.Version {
	case Version1:
		client.Version = gosnmp.Version1
	case Version2c:
		client.Version = gosnmp.Version2c
	case Version3:
		return nil, ErrNotImplemented
	default:
		return nil, fmt.Errorf("%w: %v", ErrUnsupportedSNMPVersion, target.Version)
	}

	return &SNMPClientImpl{
		client: client,
		target: target,
	}, nil
}

// Connect implements SNMPClient interface.
func (s *SNMPClientImpl) Connect() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.connected {
		return nil
	}

	if err := s.client.Connect(); err != nil {
		s.lastError = &SNMPError{
			Op:      "connect",
			Target:  s.target.Host,
			Wrapped: err,
		}

		return s.lastError
	}

	s.connected = true

	return nil
}

// Get implements SNMPClient interface.
func (s *SNMPClientImpl) Get(oids []string) (map[string]interface{}, error) {
	s.mu.Lock()
	if !s.connected {
		if err := s.client.Connect(); err != nil {
			s.mu.Unlock()

			return nil, &SNMPError{
				Op:      "connect",
				Target:  s.target.Host,
				Wrapped: err,
			}
		}

		s.connected = true
	}

	s.mu.Unlock()

	// Split OIDs into chunks of MaxOids size
	var allResults = make(map[string]interface{})

	for i := 0; i < len(oids); i += gosnmp.MaxOids {
		end := i + gosnmp.MaxOids
		if end > len(oids) {
			end = len(oids)
		}

		chunk := oids[i:end]

		result, err := s.client.Get(chunk)
		if err != nil {
			s.handleError(err)

			return nil, &SNMPError{
				Op:      "get",
				Target:  s.target.Host,
				Wrapped: err,
			}
		}

		// Process results from this chunk
		for _, variable := range result.Variables {
			value, err := s.convertVariable(variable)
			if err != nil {
				return nil, &SNMPError{
					Op:      "convert",
					Target:  s.target.Host,
					Wrapped: err,
				}
			}

			allResults[variable.Name] = value
		}
	}

	return allResults, nil
}

// Close implements SNMPClient interface.
func (s *SNMPClientImpl) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.connected {
		return nil
	}

	err := s.client.Conn.Close()
	if err != nil {
		return err
	}

	s.connected = false

	return nil
}

// GetLastError returns the last error encountered.
func (s *SNMPClientImpl) GetLastError() error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.lastError
}

// handleError processes SNMP errors and manages reconnection.
func (s *SNMPClientImpl) handleError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.lastError = err
	s.connected = false
	s.reconnects++
}

const defaultTimeTickDuration = time.Second / 100

// convertVariable converts an SNMP variable to the appropriate Go type.
func (*SNMPClientImpl) convertVariable(variable gosnmp.SnmpPDU) (interface{}, error) {
	// Map of SNMP types to conversion functions
	conversionMap := map[gosnmp.Asn1BER]func(gosnmp.SnmpPDU) interface{}{
		gosnmp.Boolean:           convertBoolean,
		gosnmp.BitString:         convertBitString,
		gosnmp.Null:              convertNull,
		gosnmp.ObjectDescription: convertObjectDescription,
		gosnmp.Opaque:            convertOpaque,
		gosnmp.NsapAddress:       convertNsapAddress,
		gosnmp.Uinteger32:        convertUinteger32,
		gosnmp.OpaqueFloat:       convertOpaqueFloat,
		gosnmp.OpaqueDouble:      convertOpaqueDouble,
		gosnmp.Integer:           convertInteger,
		gosnmp.OctetString:       convertOctetString,
		gosnmp.ObjectIdentifier:  convertObjectIdentifier,
		gosnmp.IPAddress:         convertIPAddress,
		gosnmp.Counter32:         convertCounter32Gauge32,
		gosnmp.Gauge32:           convertCounter32Gauge32,
		gosnmp.Counter64:         convertCounter64,
		gosnmp.TimeTicks:         convertTimeTicks,
	}

	// Check for types that need an error return
	if variable.Type == gosnmp.NoSuchObject {
		return convertNoSuchObject(variable)
	}

	if variable.Type == gosnmp.NoSuchInstance {
		return convertNoSuchInstance(variable)
	}

	if variable.Type == gosnmp.EndOfMibView {
		return convertEndOfMibView(variable)
	}

	// Check for EndOfContents and UnknownType explicitly
	if variable.Type == gosnmp.UnknownType {
		return convertEndOfContents(variable)
	}

	// Look up the appropriate conversion function
	if convertFunc, found := conversionMap[variable.Type]; found {
		return convertFunc(variable), nil
	}

	// Handle the case where the type is not in the map
	return nil, fmt.Errorf("%w: %v", ErrUnsupportedSNMPType, variable.Type)
}

func convertBoolean(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(bool)
}

func convertBitString(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value // Needs custom decoding
}

func convertNull(gosnmp.SnmpPDU) interface{} {
	return nil
}

func convertObjectDescription(variable gosnmp.SnmpPDU) interface{} {
	return string(variable.Value.(byte))
}

func convertOpaque(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value // Needs custom decoding
}

func convertNsapAddress(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value
}

func convertUinteger32(variable gosnmp.SnmpPDU) interface{} {
	return uint64(variable.Value.(uint))
}

func convertOpaqueFloat(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(float32)
}

func convertOpaqueDouble(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(float64)
}

func convertInteger(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(int)
}

func convertOctetString(variable gosnmp.SnmpPDU) interface{} {
	return string(variable.Value.(byte))
}

func convertObjectIdentifier(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(string)
}

func convertIPAddress(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(string)
}

func convertCounter32Gauge32(variable gosnmp.SnmpPDU) interface{} {
	return uint64(variable.Value.(uint))
}

func convertCounter64(variable gosnmp.SnmpPDU) interface{} {
	return variable.Value.(uint64)
}

func convertTimeTicks(variable gosnmp.SnmpPDU) interface{} {
	return time.Duration(variable.Value.(uint32)) * defaultTimeTickDuration
}

func convertNoSuchObject(gosnmp.SnmpPDU) (interface{}, error) {
	return nil, ErrSNMPNoSuchObject
}

func convertNoSuchInstance(gosnmp.SnmpPDU) (interface{}, error) {
	return nil, ErrSNMPNoSuchInstance
}

func convertEndOfMibView(gosnmp.SnmpPDU) (interface{}, error) {
	return nil, ErrSNMPEndOfMibView
}

// Handle the combined case for EndOfContents and UnknownType.
func convertEndOfContents(variable gosnmp.SnmpPDU) (interface{}, error) {
	if variable.Type == gosnmp.UnknownType {
		return nil, ErrSNMPUnknownType
	}

	return nil, ErrSNMPEndOfContents
}

// validateTarget performs basic validation of target configuration.
func validateTarget(target *Target) error {
	if target == nil {
		return ErrNilTargetConfig
	}

	if target.Host == "" {
		return ErrTargetHostRequired
	}

	if target.Port == 0 {
		target.Port = defaultPort
	}

	if target.Timeout == 0 {
		target.Timeout = Duration(defaultTimeout)
	}

	if target.Retries == 0 {
		target.Retries = defaultRetries
	}

	return nil
}
