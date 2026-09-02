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

// Package snmp pkg/agent/snmp/client.go
package snmp

import (
	"errors"
	"fmt"
	"strings"
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
		if err := applySNMPv3(client, target); err != nil {
			return nil, err
		}
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

// ensureConnected lazily establishes the SNMP connection before a request.
func (s *SNMPClientImpl) ensureConnected() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.connected {
		return nil
	}

	if err := s.client.Connect(); err != nil {
		return &SNMPError{
			Op:      "connect",
			Target:  s.target.Host,
			Wrapped: err,
		}
	}

	s.connected = true

	return nil
}

// Get implements SNMPClient interface.
func (s *SNMPClientImpl) Get(oids []string) (map[string]interface{}, error) {
	if err := s.ensureConnected(); err != nil {
		return nil, err
	}

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

		chunkResults, err := s.collectChunkResults(result.Variables)
		if err != nil {
			return nil, &SNMPError{
				Op:      "convert",
				Target:  s.target.Host,
				Wrapped: err,
			}
		}

		for name, value := range chunkResults {
			allResults[name] = value
		}
	}

	return allResults, nil
}

func (s *SNMPClientImpl) collectChunkResults(variables []gosnmp.SnmpPDU) (map[string]interface{}, error) {
	results := make(map[string]interface{}, len(variables))

	for _, variable := range variables {
		value, err := s.convertVariable(variable)
		if err != nil {
			if isSkippableValueError(err) {
				continue
			}

			return nil, err
		}

		results[variable.Name] = value
	}

	return results, nil
}

func isSkippableValueError(err error) bool {
	return errors.Is(err, ErrSNMPNoSuchObject) ||
		errors.Is(err, ErrSNMPNoSuchInstance) ||
		errors.Is(err, ErrSNMPEndOfMibView)
}

// Walk implements SNMPClient interface.
//
// The subtree rooted at oid is retrieved with GETBULK on v2c/v3 and with GETNEXT
// on v1, which has no GETBULK PDU. The walk is bounded by maxRows and timeout: a
// table that keeps producing rows (or a device that answers slowly) stops at the
// bound instead of stalling the collector, and the rows gathered before the bound
// are returned alongside ErrSNMPWalkRowLimit / ErrSNMPWalkTimeout so a partial
// table is still usable.
func (s *SNMPClientImpl) Walk(oid string, maxRows int, timeout time.Duration) ([]WalkResult, error) {
	if err := s.ensureConnected(); err != nil {
		return nil, err
	}

	collector := newWalkCollector(s, oid, maxRows, timeout)

	var err error

	if usesBulkWalk(s.client.Version) {
		err = s.client.BulkWalk(oid, collector.visit)
	} else {
		err = s.client.Walk(oid, collector.visit)
	}

	if err != nil {
		// A bound is not a transport failure - the connection is still usable and
		// the rows collected so far are real, so hand them back with the reason.
		if isWalkBoundError(err) {
			return collector.results, err
		}

		s.handleError(err)

		return nil, &SNMPError{
			Op:      "walk",
			Target:  s.target.Host,
			Wrapped: err,
		}
	}

	return collector.results, nil
}

// walkCollector accumulates the rows a walk visits. It converts each PDU with the
// same rules as a GET response and enforces the walk's row and time bounds.
type walkCollector struct {
	client   *SNMPClientImpl
	rootOID  string
	maxRows  int
	deadline time.Time
	results  []WalkResult
}

// newWalkCollector creates a collector bounded by maxRows and timeout, falling
// back to the package defaults when either is unset.
func newWalkCollector(client *SNMPClientImpl, rootOID string, maxRows int, timeout time.Duration) *walkCollector {
	if maxRows <= 0 {
		maxRows = defaultWalkMaxRows
	}

	if timeout <= 0 {
		timeout = defaultWalkTimeout
	}

	return &walkCollector{
		client:   client,
		rootOID:  rootOID,
		maxRows:  maxRows,
		deadline: time.Now().Add(timeout),
		results:  make([]WalkResult, 0, defaultWalkResultCapacity),
	}
}

// visit implements gosnmp.WalkFunc; returning an error stops the walk.
func (w *walkCollector) visit(variable gosnmp.SnmpPDU) error {
	if len(w.results) >= w.maxRows {
		return fmt.Errorf("%w: %s after %d rows", ErrSNMPWalkRowLimit, w.rootOID, w.maxRows)
	}

	if time.Now().After(w.deadline) {
		return fmt.Errorf("%w: %s after %d rows", ErrSNMPWalkTimeout, w.rootOID, len(w.results))
	}

	value, err := w.client.convertVariable(variable)
	if err != nil {
		if isSkippableValueError(err) {
			return nil
		}

		return err
	}

	w.results = append(w.results, WalkResult{
		OID:   variable.Name,
		Index: walkIndex(w.rootOID, variable.Name),
		Value: value,
	})

	return nil
}

// isWalkBoundError reports whether a walk stopped because it hit one of its
// configured bounds rather than because the device or transport failed.
func isWalkBoundError(err error) bool {
	return errors.Is(err, ErrSNMPWalkRowLimit) || errors.Is(err, ErrSNMPWalkTimeout)
}

// usesBulkWalk reports whether a walk should use GETBULK. SNMPv1 has no GETBULK
// PDU, so it walks with GETNEXT instead.
func usesBulkWalk(version gosnmp.SnmpVersion) bool {
	return version != gosnmp.Version1
}

// walkIndex returns the OID suffix identifying a walked row - the part of oid
// below rootOID. Values from parallel column subtrees that share an index belong
// to the same table row, which is what makes the columns joinable.
func walkIndex(rootOID, oid string) string {
	root := strings.TrimPrefix(rootOID, ".")
	trimmed := strings.TrimPrefix(oid, ".")

	switch {
	case trimmed == root:
		// The walked root is itself a leaf instance, so there is no row index.
		return ""
	case strings.HasPrefix(trimmed, root+"."):
		return strings.TrimPrefix(trimmed, root+".")
	default:
		return ""
	}
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
		gosnmp.Boolean:          convertBoolean,
		gosnmp.BitString:        convertBitString,
		gosnmp.Null:             convertNull,
		gosnmp.Opaque:           convertOpaque,
		gosnmp.NsapAddress:      convertNsapAddress,
		gosnmp.Uinteger32:       convertUinteger32,
		gosnmp.OpaqueFloat:      convertOpaqueFloat,
		gosnmp.OpaqueDouble:     convertOpaqueDouble,
		gosnmp.Integer:          convertInteger,
		gosnmp.ObjectIdentifier: convertObjectIdentifier,
		gosnmp.IPAddress:        convertIPAddress,
		gosnmp.Counter32:        convertCounter32,
		gosnmp.Gauge32:          convertCounter32Gauge32,
		gosnmp.Counter64:        convertCounter64,
		gosnmp.TimeTicks:        convertTimeTicks,
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

	if variable.Type == gosnmp.ObjectDescription {
		return convertObjectDescription(variable)
	}

	if variable.Type == gosnmp.OctetString {
		return convertOctetString(variable)
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

func convertObjectDescription(variable gosnmp.SnmpPDU) (interface{}, error) {
	bytes, ok := variable.Value.([]byte)
	if !ok {
		return nil, fmt.Errorf("%w: ObjectDescription expected []byte, got %T", ErrSNMPConvert, variable.Value)
	}

	return string(bytes), nil
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

func convertOctetString(variable gosnmp.SnmpPDU) (interface{}, error) {
	bytes, ok := variable.Value.([]byte)
	if !ok {
		return nil, fmt.Errorf("%w: OctetString expected []byte, got %T", ErrSNMPConvert, variable.Value)
	}

	return string(bytes), nil
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

func convertCounter32(variable gosnmp.SnmpPDU) interface{} {
	return CounterValue{Value: uint64(variable.Value.(uint)), Width: 32}
}

func convertCounter64(variable gosnmp.SnmpPDU) interface{} {
	return CounterValue{Value: variable.Value.(uint64), Width: 64}
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

func applySNMPv3(client *gosnmp.GoSNMP, target *Target) error {
	if target.V3Auth == nil {
		return fmt.Errorf("%w: SNMPv3 requires V3Auth configuration", ErrInvalidTargetConfig)
	}

	flags, err := securityLevelToMsgFlags(target.V3Auth.SecurityLevel)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidTargetConfig, err)
	}

	usm := &gosnmp.UsmSecurityParameters{
		UserName: target.V3Auth.Username,
	}

	if flags == gosnmp.AuthNoPriv || flags == gosnmp.AuthPriv {
		authProto, err := authProtocolToGoSNMP(target.V3Auth.AuthProtocol)
		if err != nil {
			return fmt.Errorf("%w: %w", ErrInvalidTargetConfig, err)
		}

		if strings.TrimSpace(target.V3Auth.AuthPassword) == "" {
			return fmt.Errorf("%w: %w", ErrInvalidTargetConfig, ErrIncompleteSNMPv3Auth)
		}

		usm.AuthenticationProtocol = authProto
		usm.AuthenticationPassphrase = target.V3Auth.AuthPassword
	}

	if flags == gosnmp.AuthPriv {
		privProto, err := privProtocolToGoSNMP(target.V3Auth.PrivProtocol)
		if err != nil {
			return fmt.Errorf("%w: %w", ErrInvalidTargetConfig, err)
		}

		if strings.TrimSpace(target.V3Auth.PrivPassword) == "" {
			return fmt.Errorf("%w: %w", ErrInvalidTargetConfig, ErrIncompleteSNMPv3Auth)
		}

		usm.PrivacyProtocol = privProto
		usm.PrivacyPassphrase = target.V3Auth.PrivPassword
	}

	client.Version = gosnmp.Version3
	client.SecurityModel = gosnmp.UserSecurityModel
	client.MsgFlags = flags
	client.SecurityParameters = usm

	return nil
}

func securityLevelToMsgFlags(sl SecurityLevel) (gosnmp.SnmpV3MsgFlags, error) {
	switch SecurityLevel(compactProtocol(string(sl))) {
	case "", SecurityLevelNoAuthNoPriv, "noauthnopriv":
		return gosnmp.NoAuthNoPriv, nil
	case SecurityLevelAuthNoPriv, "authnopriv":
		return gosnmp.AuthNoPriv, nil
	case SecurityLevelAuthPriv, "authpriv":
		return gosnmp.AuthPriv, nil
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPSecurityLevel, sl)
	}
}

func authProtocolToGoSNMP(ap AuthProtocol) (gosnmp.SnmpV3AuthProtocol, error) {
	switch compactProtocol(string(ap)) {
	case "md5":
		return gosnmp.MD5, nil
	case "sha", "sha1":
		return gosnmp.SHA, nil
	case "sha224":
		return gosnmp.SHA224, nil
	case "sha256":
		return gosnmp.SHA256, nil
	case "sha384":
		return gosnmp.SHA384, nil
	case "sha512":
		return gosnmp.SHA512, nil
	case "":
		return 0, fmt.Errorf("%w: auth protocol is required", ErrUnknownSNMPAuthProtocol)
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPAuthProtocol, ap)
	}
}

func privProtocolToGoSNMP(pp PrivProtocol) (gosnmp.SnmpV3PrivProtocol, error) {
	switch compactProtocol(string(pp)) {
	case "des":
		return gosnmp.DES, nil
	case "aes", "aes128":
		return gosnmp.AES, nil
	case "aes192":
		return gosnmp.AES192, nil
	case "aes256":
		return gosnmp.AES256, nil
	case "aes192c":
		return gosnmp.AES192C, nil
	case "aes256c":
		return gosnmp.AES256C, nil
	case "":
		return 0, fmt.Errorf("%w: privacy protocol is required", ErrUnknownSNMPPrivProtocol)
	default:
		return 0, fmt.Errorf("%w: %s", ErrUnknownSNMPPrivProtocol, pp)
	}
}

func compactProtocol(value string) string {
	trimmed := strings.ToLower(strings.TrimSpace(value))
	trimmed = strings.ReplaceAll(trimmed, "-", "")
	trimmed = strings.ReplaceAll(trimmed, "_", "")

	return trimmed
}
