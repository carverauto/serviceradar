package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

const (
	maxJSONNesting           = 256
	maxJSONTokensPerDocument = 8_000_000
	maxOSVRangeEntries       = 2
	maxOSVRangeEvents        = 2
	maxOSVEventFields        = 2
	maxJSONFieldBytes        = 4 << 10
	maxJSONIntegerBytes      = 20
	maxJSONObjectFields      = 4 << 10
	maxJSONStoredFields      = 64 << 10
	maxJSONStoredFieldBytes  = 8 << 20
	fieldSeparator           = "\x00"
	osvDocumentFields        = "id\x00details\x00aliases\x00upstream\x00related\x00severity\x00published\x00modified\x00withdrawn\x00affected\x00references"
	osvAffectedFields        = "package\x00ranges\x00versions\x00ecosystem_specific"
	osvPackageFields         = "ecosystem\x00name\x00purl"
	osvRangeFields           = "type\x00events"
	osvEcosystemFields       = "binaries"
	osvBinaryFields          = "binary_name\x00binary_version"
	osvSeverityFields        = "type\x00score"
	osvReferenceFields       = "type\x00url"
	vexContextField          = "@context"
	vexIDField               = "@id"
	vexAuthorField           = "author"
	vexTimestampField        = "timestamp"
	vexLastUpdatedField      = "last_updated"
	vexVersionField          = "version"
	vexDocumentFields        = vexContextField + fieldSeparator + vexIDField + "\x00author\x00timestamp\x00last_updated\x00version\x00metadata\x00statements"
	vexMetadataFieldNames    = vexContextField + fieldSeparator + vexIDField + "\x00author\x00timestamp\x00last_updated\x00version"
	vexStatementFields       = "vulnerability\x00timestamp\x00last_updated\x00action_statement_timestamp\x00version\x00products\x00status\x00justification\x00status_notes\x00action_statement\x00impact_statement"
	vexVulnerabilityFields   = vexIDField + "\x00name\x00description\x00aliases"
	vexProductFields         = vexIDField + "\x00identifiers\x00subcomponents"
	vexIdentifierFields      = "purl"
)

type documentStructure struct {
	osvID string
	vex   vexStructure
}

type vexStructure struct {
	statementsPresent bool
	statementCount    int64
	top               vexMetadataFields
	metadataPresent   bool
	metadata          vexMetadataFields
}

type vexMetadataFields struct {
	context        string
	contextPresent bool
	id             string
	idPresent      bool
	author         string
	authorPresent  bool
	timestamp      string
	timestampSet   bool
	lastUpdated    string
	lastUpdatedSet bool
	version        int64
	versionPresent bool
}

type structuralPreflight struct {
	decoder          *json.Decoder
	limits           projectionLimits
	tokens           int64
	nesting          int
	logicalProducts  int64
	containers       []jsonContainer
	storedFields     int64
	storedFieldBytes int64
}

type jsonContainer struct {
	delimiter  json.Delim
	fields     map[string]struct{}
	fieldBytes int64
}

func preflightDocumentStructure(kind, cve string, raw []byte, limits projectionLimits) (documentStructure, error) {
	if limits.logicalProducts <= 0 || limits.assertions <= 0 || limits.jsonTokens <= 0 || limits.jsonNesting <= 0 {
		return documentStructure{}, newDiagnostic("invalid projection limits")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	preflight := &structuralPreflight{decoder: decoder, limits: limits}
	var structure documentStructure
	var err error
	switch kind {
	case osvKind:
		structure.osvID, err = preflight.scanOSVDocument()
		if err == nil && structure.osvID != "UBUNTU-"+cve {
			err = newDiagnostic("OSV identity mismatch")
		}
	case vexKind:
		structure.vex, err = preflight.scanVEXDocument(cve)
	default:
		err = newDiagnostic("unknown advisory document kind")
	}
	if err != nil {
		return documentStructure{}, err
	}
	if err := preflight.finish(); err != nil {
		return documentStructure{}, err
	}
	return structure, nil
}

func (preflight *structuralPreflight) nextToken() (json.Token, error) {
	if preflight.tokens >= preflight.limits.jsonTokens {
		return nil, newDiagnostic("JSON token cap exceeded")
	}
	token, err := preflight.decoder.Token()
	if err != nil {
		return nil, err
	}
	preflight.tokens++
	return token, nil
}

func (preflight *structuralPreflight) finish() error {
	_, err := preflight.decoder.Token()
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err != nil {
		return err
	}
	return newDiagnostic("multiple JSON values")
}

func (preflight *structuralPreflight) startContainer(want json.Delim, allowNull bool) (bool, error) {
	token, err := preflight.nextToken()
	if err != nil {
		return false, err
	}
	if token == nil && allowNull {
		return false, nil
	}
	delimiter, ok := token.(json.Delim)
	if !ok || delimiter != want {
		return false, newDiagnostic("invalid JSON structure")
	}
	if preflight.nesting >= preflight.limits.jsonNesting {
		return false, newDiagnostic("JSON nesting cap exceeded")
	}
	preflight.nesting++
	preflight.containers = append(preflight.containers, jsonContainer{delimiter: want})
	return true, nil
}

func (preflight *structuralPreflight) finishContainer(want json.Delim) error {
	token, err := preflight.nextToken()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok || delimiter != want {
		return newDiagnostic("invalid JSON structure")
	}
	if preflight.nesting <= 0 || len(preflight.containers) != preflight.nesting || preflight.containers[len(preflight.containers)-1].delimiter != matchingOpenDelimiter(want) {
		return newDiagnostic("invalid JSON structure")
	}
	last := len(preflight.containers) - 1
	container := preflight.containers[last]
	fieldCount := int64(len(container.fields))
	if preflight.storedFields < fieldCount || container.fieldBytes < 0 || preflight.storedFieldBytes < container.fieldBytes {
		return newDiagnostic("invalid JSON field storage accounting")
	}
	preflight.storedFields -= fieldCount
	preflight.storedFieldBytes -= container.fieldBytes
	preflight.nesting--
	preflight.containers[last] = jsonContainer{}
	preflight.containers = preflight.containers[:last]
	return nil
}

func matchingOpenDelimiter(close json.Delim) json.Delim {
	if close == '}' {
		return '{'
	}
	return '['
}

func (preflight *structuralPreflight) nextFieldName() (string, error) {
	token, err := preflight.nextToken()
	if err != nil {
		return "", err
	}
	field, ok := token.(string)
	if !ok {
		return "", newDiagnostic("invalid JSON object field")
	}
	if len(field) > maxJSONFieldBytes {
		return "", newDiagnostic("JSON object field cap exceeded")
	}
	if preflight.nesting <= 0 || len(preflight.containers) != preflight.nesting {
		return "", newDiagnostic("JSON object field outside object")
	}
	container := &preflight.containers[len(preflight.containers)-1]
	if container.delimiter != '{' {
		return "", newDiagnostic("JSON object field outside object")
	}
	if _, exists := container.fields[field]; exists {
		return "", diagnosticf("duplicate JSON field %q", field)
	}
	if len(container.fields) >= maxJSONObjectFields || preflight.storedFields >= maxJSONStoredFields || int64(len(field)) > maxJSONStoredFieldBytes-preflight.storedFieldBytes {
		return "", newDiagnostic("JSON object field storage cap exceeded")
	}
	if container.fields == nil {
		container.fields = make(map[string]struct{})
	}
	container.fields[field] = struct{}{}
	container.fieldBytes += int64(len(field))
	preflight.storedFields++
	preflight.storedFieldBytes += int64(len(field))
	return field, nil
}

func canonicalField(field, known string) (string, error) {
	noncanonical := false
	for {
		candidate, remainder, found := strings.Cut(known, fieldSeparator)
		if field == candidate {
			return candidate, nil
		}
		noncanonical = noncanonical || strings.EqualFold(field, candidate)
		if !found {
			break
		}
		known = remainder
	}
	if noncanonical {
		return "", diagnosticf("noncanonical JSON field %q", field)
	}
	return "", nil
}

func (preflight *structuralPreflight) skipValue() error {
	token, err := preflight.nextToken()
	if err != nil {
		return err
	}
	return preflight.skipStartedValue(token)
}

func (preflight *structuralPreflight) skipStartedValue(token json.Token) error {
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	var closeDelimiter json.Delim
	switch delimiter {
	case '{':
		closeDelimiter = '}'
	case '[':
		closeDelimiter = ']'
	default:
		return newDiagnostic("invalid JSON structure")
	}
	if preflight.nesting >= preflight.limits.jsonNesting {
		return newDiagnostic("JSON nesting cap exceeded")
	}
	preflight.nesting++
	preflight.containers = append(preflight.containers, jsonContainer{delimiter: delimiter})
	for preflight.decoder.More() {
		if delimiter == '{' {
			if _, err := preflight.nextFieldName(); err != nil {
				return err
			}
		}
		if err := preflight.skipValue(); err != nil {
			return err
		}
	}
	return preflight.finishContainer(closeDelimiter)
}

func (preflight *structuralPreflight) scanCappedArray(allowNull bool, limit int64, capError string, scanElement func() error) (int64, error) {
	started, err := preflight.startContainer('[', allowNull)
	if err != nil || !started {
		return 0, err
	}
	var count int64
	for preflight.decoder.More() {
		if limit < 0 || count >= limit {
			return 0, newDiagnostic(capError)
		}
		count++
		if scanElement == nil {
			err = preflight.skipValue()
		} else {
			err = scanElement()
		}
		if err != nil {
			return 0, err
		}
	}
	if err := preflight.finishContainer(']'); err != nil {
		return 0, err
	}
	return count, nil
}

func (preflight *structuralPreflight) scanBoundedStringArray(allowNull bool, countLimit int64, countError string, stringLimit int, stringError string) (int64, error) {
	return preflight.scanCappedArray(allowNull, countLimit, countError, func() error {
		_, err := preflight.readBoundedString(stringLimit, stringError)
		return err
	})
}

func (preflight *structuralPreflight) reserveLogicalProduct() error {
	if preflight.limits.logicalProducts <= 0 || preflight.logicalProducts >= preflight.limits.logicalProducts {
		return newDiagnostic("logical product cap exceeded")
	}
	preflight.logicalProducts++
	return nil
}

func (preflight *structuralPreflight) scanOSVDocument() (string, error) {
	started, err := preflight.startContainer('{', false)
	if err != nil || !started {
		return "", err
	}
	id := ""
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return "", err
		}
		field, err = canonicalField(field, osvDocumentFields)
		if err != nil {
			return "", err
		}
		switch field {
		case "id":
			id, err = preflight.readBoundedString(maxEvidenceBytes, "OSV identity component cap exceeded")
		case "details":
			_, err = preflight.readBoundedString(maxDescriptionBytes, "OSV description cap exceeded")
		case "aliases", "upstream", "related":
			_, err = preflight.scanBoundedStringArray(true, maxReferences, "OSV identity-reference cap exceeded", maxEvidenceBytes, "OSV identity-reference component cap exceeded")
		case "severity":
			_, err = preflight.scanCappedArray(true, maxReferences, "OSV severity cap exceeded", preflight.scanOSVSeverity)
		case "references":
			_, err = preflight.scanCappedArray(true, maxReferences, "OSV reference cap exceeded", preflight.scanOSVReference)
		case "published", "modified", "withdrawn":
			_, err = preflight.readBoundedString(maxEvidenceBytes, "OSV timestamp component cap exceeded")
		case "affected":
			_, err = preflight.scanCappedArray(true, preflight.limits.assertions, "assertion cap exceeded", preflight.scanOSVAffected)
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return "", err
		}
	}
	if err := preflight.finishContainer('}'); err != nil {
		return "", err
	}
	return id, nil
}

func (preflight *structuralPreflight) scanOSVAffected() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, osvAffectedFields)
		if err != nil {
			return err
		}
		switch field {
		case "package":
			err = preflight.scanOSVPackage()
		case "ranges":
			_, err = preflight.scanCappedArray(true, maxOSVRangeEntries, "OSV range cap exceeded", preflight.scanOSVRange)
		case "versions":
			_, err = preflight.scanLogicalProductArray()
		case "ecosystem_specific":
			err = preflight.scanOSVEcosystemSpecific()
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVPackage() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, osvPackageFields)
		if err != nil {
			return err
		}
		if field == "" {
			err = preflight.skipValue()
		} else {
			_, err = preflight.readBoundedString(maxPURLBytes, "OSV product component cap exceeded")
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVRange() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, osvRangeFields)
		if err != nil {
			return err
		}
		switch field {
		case "events":
			_, err = preflight.scanCappedArray(true, maxOSVRangeEvents, "OSV range event cap exceeded", preflight.scanOSVEvent)
		case "type":
			_, err = preflight.readBoundedString(maxEvidenceBytes, "OSV range component cap exceeded")
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVEvent() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	fields := 0
	for preflight.decoder.More() {
		if fields >= maxOSVEventFields {
			return newDiagnostic("OSV range event field cap exceeded")
		}
		fields++
		if _, err := preflight.nextFieldName(); err != nil {
			return err
		}
		if _, err := preflight.readBoundedString(maxPURLBytes, "OSV product component cap exceeded"); err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVEcosystemSpecific() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, osvEcosystemFields)
		if err != nil {
			return err
		}
		if field == "binaries" {
			_, err = preflight.scanCappedArray(true, preflight.limits.logicalProducts, "logical product cap exceeded", func() error {
				if err := preflight.reserveLogicalProduct(); err != nil {
					return err
				}
				return preflight.scanOSVBinary()
			})
		} else {
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVBinary() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, osvBinaryFields)
		if err != nil {
			return err
		}
		if field == "" {
			err = preflight.skipValue()
		} else {
			_, err = preflight.readBoundedString(maxPURLBytes, "OSV product component cap exceeded")
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanOSVSeverity() error {
	return preflight.scanBoundedStringObject(osvSeverityFields, maxEvidenceBytes, "OSV severity component cap exceeded")
}

func (preflight *structuralPreflight) scanOSVReference() error {
	return preflight.scanBoundedStringObject(osvReferenceFields, maxEvidenceBytes, "OSV reference component cap exceeded")
}

func (preflight *structuralPreflight) scanBoundedStringObject(fields string, limit int, capError string) error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, fields)
		if err != nil {
			return err
		}
		if field == "" {
			err = preflight.skipValue()
		} else {
			_, err = preflight.readBoundedString(limit, capError)
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanLogicalProductArray() (int64, error) {
	return preflight.scanCappedArray(true, preflight.limits.logicalProducts, "logical product cap exceeded", func() error {
		if err := preflight.reserveLogicalProduct(); err != nil {
			return err
		}
		_, err := preflight.readBoundedString(maxPURLBytes, "OSV product component cap exceeded")
		return err
	})
}

func (preflight *structuralPreflight) scanVEXDocument(cve string) (vexStructure, error) {
	var structure vexStructure
	started, err := preflight.startContainer('{', false)
	if err != nil || !started {
		return structure, err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return vexStructure{}, err
		}
		field, err = canonicalField(field, vexDocumentFields)
		if err != nil {
			return vexStructure{}, err
		}
		switch field {
		case vexContextField, vexIDField, vexAuthorField, vexTimestampField, vexLastUpdatedField, vexVersionField:
			err = preflight.scanVEXMetadataField(&structure.top, field)
		case "metadata":
			structure.metadataPresent = true
			structure.metadata, err = preflight.scanVEXMetadata()
		case "statements":
			structure.statementsPresent = true
			structure.statementCount, err = preflight.scanCappedArray(false, preflight.limits.assertions, "assertion cap exceeded", func() error {
				return preflight.scanVEXStatement(cve)
			})
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return vexStructure{}, err
		}
	}
	if err := preflight.finishContainer('}'); err != nil {
		return vexStructure{}, err
	}
	if !structure.statementsPresent {
		return vexStructure{}, newDiagnostic("VEX statements missing")
	}
	if structure.statementCount == 0 {
		if err := validateStructuralVEXTombstone(structure, cve); err != nil {
			return vexStructure{}, err
		}
	}
	return structure, nil
}

func (preflight *structuralPreflight) scanVEXStatement(cve string) error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	vulnerabilityName := ""
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, vexStatementFields)
		if err != nil {
			return err
		}
		switch field {
		case "vulnerability":
			vulnerabilityName, err = preflight.scanVEXVulnerability()
		case "products":
			err = preflight.scanVEXProducts(0)
		case vexVersionField:
			_, err = preflight.readNullableInt64()
		case vexTimestampField, vexLastUpdatedField, "action_statement_timestamp", "status", "justification", "status_notes", "action_statement", "impact_statement":
			_, err = preflight.readBoundedString(maxEvidenceBytes, "VEX statement component cap exceeded")
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	if err := preflight.finishContainer('}'); err != nil {
		return err
	}
	if vulnerabilityName != cve {
		return newDiagnostic("VEX identity mismatch")
	}
	return nil
}

func (preflight *structuralPreflight) scanVEXVulnerability() (string, error) {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return "", err
	}
	name := ""
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return "", err
		}
		field, err = canonicalField(field, vexVulnerabilityFields)
		if err != nil {
			return "", err
		}
		switch field {
		case "name":
			name, err = preflight.readBoundedString(maxEvidenceBytes, "VEX vulnerability component cap exceeded")
		case vexIDField:
			_, err = preflight.readBoundedString(maxEvidenceBytes, "VEX vulnerability component cap exceeded")
		case "description":
			_, err = preflight.readBoundedString(maxDescriptionBytes, "VEX vulnerability description cap exceeded")
		case "aliases":
			_, err = preflight.scanBoundedStringArray(true, maxReferences, "too many vulnerability aliases", maxEvidenceBytes, "VEX vulnerability alias component cap exceeded")
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return "", err
		}
	}
	if err := preflight.finishContainer('}'); err != nil {
		return "", err
	}
	return name, nil
}

func (preflight *structuralPreflight) scanVEXProducts(depth int) error {
	started, err := preflight.startContainer('[', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		if depth > maxProductDepth {
			return newDiagnostic("VEX product nesting cap exceeded")
		}
		if err := preflight.reserveLogicalProduct(); err != nil {
			return err
		}
		if err := preflight.scanVEXProduct(depth); err != nil {
			return err
		}
	}
	return preflight.finishContainer(']')
}

func (preflight *structuralPreflight) scanVEXProduct(depth int) error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, vexProductFields)
		if err != nil {
			return err
		}
		switch field {
		case "subcomponents":
			err = preflight.scanVEXProducts(depth + 1)
		case vexIDField:
			_, err = preflight.readBoundedString(maxEvidenceBytes, "VEX product component cap exceeded")
		case "identifiers":
			err = preflight.scanVEXIdentifiers()
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanVEXIdentifiers() error {
	started, err := preflight.startContainer('{', true)
	if err != nil || !started {
		return err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return err
		}
		field, err = canonicalField(field, vexIdentifierFields)
		if err != nil {
			return err
		}
		if field == "purl" {
			_, err = preflight.readBoundedString(maxPURLBytes, "VEX product component cap exceeded")
		} else {
			err = preflight.skipValue()
		}
		if err != nil {
			return err
		}
	}
	return preflight.finishContainer('}')
}

func (preflight *structuralPreflight) scanVEXMetadata() (vexMetadataFields, error) {
	var fields vexMetadataFields
	started, err := preflight.startContainer('{', false)
	if err != nil || !started {
		return fields, err
	}
	for preflight.decoder.More() {
		field, err := preflight.nextFieldName()
		if err != nil {
			return vexMetadataFields{}, err
		}
		field, err = canonicalField(field, vexMetadataFieldNames)
		if err != nil {
			return vexMetadataFields{}, err
		}
		switch field {
		case vexContextField, vexIDField, vexAuthorField, vexTimestampField, vexLastUpdatedField, vexVersionField:
			err = preflight.scanVEXMetadataField(&fields, field)
		default:
			err = preflight.skipValue()
		}
		if err != nil {
			return vexMetadataFields{}, err
		}
	}
	if err := preflight.finishContainer('}'); err != nil {
		return vexMetadataFields{}, err
	}
	return fields, nil
}

func (preflight *structuralPreflight) scanVEXMetadataField(fields *vexMetadataFields, field string) error {
	if field == vexVersionField {
		value, err := preflight.readNullableInt64()
		if err != nil {
			return err
		}
		fields.version, fields.versionPresent = value, true
		return nil
	}
	value, err := preflight.readBoundedString(maxEvidenceBytes, "VEX metadata component cap exceeded")
	if err != nil {
		return err
	}
	switch field {
	case "@context":
		fields.context, fields.contextPresent = value, true
	case vexIDField:
		fields.id, fields.idPresent = value, true
	case vexAuthorField:
		fields.author, fields.authorPresent = value, true
	case vexTimestampField:
		fields.timestamp, fields.timestampSet = value, true
	case vexLastUpdatedField:
		fields.lastUpdated, fields.lastUpdatedSet = value, true
	}
	return nil
}

func (preflight *structuralPreflight) readBoundedString(limit int, capError string) (string, error) {
	token, err := preflight.nextToken()
	if err != nil {
		return "", err
	}
	if token == nil {
		return "", nil
	}
	value, ok := token.(string)
	if !ok {
		return "", newDiagnostic("invalid JSON string")
	}
	if limit < 0 || len(value) > limit {
		return "", newDiagnostic(capError)
	}
	return value, nil
}

func (preflight *structuralPreflight) readNullableInt64() (int64, error) {
	token, err := preflight.nextToken()
	if err != nil {
		return 0, err
	}
	if token == nil {
		return 0, nil
	}
	number, ok := token.(json.Number)
	if !ok {
		return 0, newDiagnostic("invalid JSON integer")
	}
	if len(number.String()) > maxJSONIntegerBytes {
		return 0, newDiagnostic("JSON integer component cap exceeded")
	}
	value, err := number.Int64()
	if err != nil {
		return 0, newDiagnostic("invalid JSON integer")
	}
	return value, nil
}

func mergedVEXMetadata(structure vexStructure) (vexMetadataFields, error) {
	if !structure.metadataPresent {
		return structure.top, nil
	}
	checks := []struct {
		field           string
		topPresent      bool
		topValue        string
		metadataValue   string
		metadataPresent bool
	}{
		{"@context", structure.top.contextPresent, structure.top.context, structure.metadata.context, structure.metadata.contextPresent},
		{vexIDField, structure.top.idPresent, structure.top.id, structure.metadata.id, structure.metadata.idPresent},
		{vexAuthorField, structure.top.authorPresent, structure.top.author, structure.metadata.author, structure.metadata.authorPresent},
		{vexTimestampField, structure.top.timestampSet, structure.top.timestamp, structure.metadata.timestamp, structure.metadata.timestampSet},
		{vexLastUpdatedField, structure.top.lastUpdatedSet, structure.top.lastUpdated, structure.metadata.lastUpdated, structure.metadata.lastUpdatedSet},
	}
	for _, check := range checks {
		if check.topPresent && (!check.metadataPresent || check.topValue != check.metadataValue) {
			return vexMetadataFields{}, diagnosticf("conflicting VEX document metadata %s", check.field)
		}
	}
	if structure.top.versionPresent && (!structure.metadata.versionPresent || structure.top.version != structure.metadata.version) {
		return vexMetadataFields{}, newDiagnostic("conflicting VEX document metadata version")
	}
	return structure.metadata, nil
}

func validateStructuralVEXTombstone(structure vexStructure, cve string) error {
	metadata, err := mergedVEXMetadata(structure)
	if err != nil {
		return err
	}
	if metadata.context != canonicalTombstoneContext || metadata.id == "" || metadata.author != canonicalAuthor || metadata.version <= 0 || !validTimestamp(metadata.timestamp) {
		return newDiagnostic("invalid Canonical empty-statements tombstone metadata")
	}
	if metadata.lastUpdatedSet && !validTimestamp(metadata.lastUpdated) {
		return newDiagnostic("invalid Canonical tombstone last_updated")
	}
	for _, embedded := range cveInID.FindAllString(metadata.id, -1) {
		if embedded != cve {
			return newDiagnostic("canonical tombstone identity mismatch")
		}
	}
	return nil
}
