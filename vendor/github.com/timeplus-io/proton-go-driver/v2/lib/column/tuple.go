// Licensed to ClickHouse, Inc. under one or more contributor
// license agreements. See the NOTICE file distributed with
// this work for additional information regarding copyright
// ownership. ClickHouse, Inc. licenses this file to you under
// the Apache License, Version 2.0 (the "License"); you may
// not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package column

import (
	"database/sql"
	"fmt"
	"net"
	"reflect"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"
	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
)

type Tuple struct {
	chType  Type
	columns []Interface
	name    string
}

func (col *Tuple) Name() string {
	return col.name
}

func (col *Tuple) parse(t Type, tz *time.Location) (_ Interface, err error) {
	col.chType = t
	var (
		element       []rune
		elements      []string
		brackets      int
		appendElement = func() {
			if len(element) != 0 {
				name := strings.TrimSpace(string(element))
				if parts := strings.SplitN(name, " ", 2); len(parts) == 2 {
					if !strings.Contains(parts[0], "(") {
						name = parts[1]
					}
				}
				elements = append(elements, name)
			}
		}
	)
	for _, r := range t.params() {
		switch r {
		case '(':
			brackets++
		case ')':
			brackets--
		case ',':
			if brackets == 0 {
				appendElement()
				element = element[:0]
				continue
			}
		}
		element = append(element, r)
	}
	appendElement()
	for _, ct := range elements {
		column, err := Type(strings.TrimSpace(ct)).Column(ct, tz)
		if err != nil {
			return nil, err
		}
		col.columns = append(col.columns, column)
	}
	if len(col.columns) != 0 {
		return col, nil
	}
	return nil, &UnsupportedColumnTypeError{
		t: t,
	}
}

func (col *Tuple) Type() Type {
	return col.chType
}

func (Tuple) ScanType() reflect.Type {
	return scanTypeSlice
}

func (col *Tuple) Rows() int {
	if len(col.columns) != 0 {
		return col.columns[0].Rows()
	}
	return 0
}

func (col *Tuple) Row(i int, ptr bool) interface{} {
	tuple := make([]interface{}, 0, len(col.columns))
	for _, c := range col.columns {
		tuple = append(tuple, c.Row(i, ptr))
	}
	return tuple
}

// Copied from go/src/reflect/value.go for old Go version
func canConvert(v reflect.Value, t reflect.Type) bool {
	vt := v.Type()
	if !vt.ConvertibleTo(t) {
		return false
	}
	// Converting from slice to array or to pointer-to-array can panic
	// depending on the value.
	switch {
	case vt.Kind() == reflect.Slice && t.Kind() == reflect.Array:
		if t.Len() > v.Len() {
			return false
		}
	case vt.Kind() == reflect.Slice && t.Kind() == reflect.Ptr && t.Elem().Kind() == reflect.Array:
		n := t.Elem().Len()
		if n > v.Len() {
			return false
		}
	}
	return true
}

func setJSONFieldValue(field reflect.Value, value reflect.Value) error {
	switch field.Interface().(type) {
	case time.Time:
		if value.Kind() == reflect.String {
			sValue := value.Interface().(string)
			val, err := time.Parse("2006-01-02 15:04:05.999999999 -0700 MST", sValue)
			if err != nil {
				return &Error{
					ColumnType: fmt.Sprint(field.Type()),
					Err:        fmt.Errorf("%s cannot be parsed into a time.Time as it isn't in the default format [2006-01-02 15:04:05.999999999 -0700 MST]", sValue),
				}
			}
			field.Set(reflect.ValueOf(val))
			return nil
		}
	case decimal.Decimal:
		if value.Kind() == reflect.String {
			sValue := value.Interface().(string)
			var val decimal.Decimal
			if sValue == "" {
				field.Set(reflect.ValueOf(val))
				return nil
			}
			val, err := decimal.NewFromString(sValue)
			if err != nil {
				return &Error{
					ColumnType: fmt.Sprint(field.Type()),
					Err:        fmt.Errorf("value %s but cannot be parsed into a decimal.Decimal - %s", sValue, err),
				}
			}
			field.Set(reflect.ValueOf(val))
			return nil
		}
	case net.IP:
		if value.Kind() == reflect.String {
			sValue := value.Interface().(string)
			field.Set(reflect.ValueOf(net.ParseIP(sValue)))
			return nil
		}
	case uuid.UUID:
		if value.Kind() == reflect.String {
			sValue := value.Interface().(string)
			uuid, err := uuid.Parse(sValue)
			if err != nil {
				return &Error{
					ColumnType: fmt.Sprint(field.Type()),
					Err:        fmt.Errorf("value %s cannot be parsed into a uuid.UUID - %s", sValue, err),
				}
			}
			field.Set(reflect.ValueOf(uuid))
			return nil
		}
	}

	if canConvert(value, field.Type()) {
		field.Set(value.Convert(field.Type()))
		return nil
	}

	// check if our target implements sql.Scanner
	sqlScanner := reflect.TypeOf((*sql.Scanner)(nil)).Elem()
	if fieldAddr := field.Addr(); field.Kind() != reflect.Ptr && fieldAddr.Type().Implements(sqlScanner) {
		returns := fieldAddr.MethodByName("Scan").Call([]reflect.Value{value})
		if len(returns) > 0 && returns[0].IsNil() {
			return nil
		}
	}

	return &ColumnConverterError{
		Op:   "ScanRow",
		To:   fmt.Sprintf("%T", field.Interface()),
		From: value.Type().String(),
	}

}

func getStructFieldValue(field reflect.Value, name string) (reflect.Value, bool) {
	tField := field.Type()
	for i := 0; i < tField.NumField(); i++ {
		if tag := tField.Field(i).Tag.Get("json"); tag == name {
			return field.Field(i), true
		}
		if tag := tField.Field(i).Tag.Get("ch"); tag == name {
			return field.Field(i), true
		}
	}
	sField := field.FieldByName(name)
	return sField, sField.IsValid()
}

func unescapeColName(colName string) string {
	s := []rune(colName)
	if s[0:1][0] == '`' && s[len(s)-1:][0] == '`' {
		return colUnEscape.Replace(string(s[1 : len(s)-1]))
	}
	return colUnEscape.Replace(colName)
}

func (col *Tuple) scanMap(targetMap reflect.Value, row int) error {
	if targetMap.Type().Key().Kind() != reflect.String {
		return &Error{
			ColumnType: fmt.Sprint(targetMap.Type().Key().Kind()),
			Err:        fmt.Errorf("column %s - map keys must be a string", col.Name()),
		}
	}
	for _, c := range col.columns {
		colName := unescapeColName(c.Name())
		switch dCol := c.(type) {
		case *Tuple:
			switch targetMap.Type().Elem().Kind() {
			case reflect.Struct:
				rStruct := reflect.New(targetMap.Type().Elem()).Elem()
				if err := dCol.scanStruct(rStruct, row); err != nil {
					return err
				}
				targetMap.SetMapIndex(reflect.ValueOf(colName), rStruct)
			case reflect.Map:
				// get a typed map
				newMap := reflect.MakeMap(targetMap.Type().Elem())
				if err := dCol.scanMap(newMap, row); err != nil {
					return err
				}
				targetMap.SetMapIndex(reflect.ValueOf(colName), newMap)
			case reflect.Interface:
				// catches any - Note this swallows custom interfaces to which maps couldn't conform
				newMap := reflect.ValueOf(make(map[string]interface{}))
				if err := dCol.scanMap(newMap, row); err != nil {
					return err
				}
				targetMap.SetMapIndex(reflect.ValueOf(colName), newMap)
			default:
				return &Error{
					ColumnType: fmt.Sprint(targetMap.Type().Elem().Kind()),
					Err:        fmt.Errorf("column %s - needs a map/struct or any", col.Name()),
				}
			}
		case *Nested:
			aCol := dCol.Interface.(*Array)
			subSlice, err := aCol.scan(targetMap.Type().Elem(), row)
			if err != nil {
				return err
			}
			// this wont work if targetMap is a map[string][]any and we try to set a typed slice
			targetMap.SetMapIndex(reflect.ValueOf(colName), subSlice)
		case *Array:
			subSlice, err := dCol.scan(targetMap.Type().Elem(), row)
			if err != nil {
				return err
			}
			targetMap.SetMapIndex(reflect.ValueOf(colName), subSlice)
		default:
			val := c.Row(row, false)
			if val != nil {
				field := reflect.New(reflect.TypeOf(val)).Elem()
				value := reflect.ValueOf(val)
				if err := setJSONFieldValue(field, value); err != nil {
					return err
				}
				targetMap.SetMapIndex(reflect.ValueOf(colName), field)
			} else {
				if _, isNullable := c.(*Nullable); !isNullable {
					targetMap.SetMapIndex(reflect.ValueOf(colName), reflect.Zero(c.ScanType().Elem()))
				} else {
					targetMap.SetMapIndex(reflect.ValueOf(colName), reflect.Zero(c.ScanType()))
				}
			}

		}
	}
	return nil
}

func (col *Tuple) scanStruct(targetStruct reflect.Value, row int) error {
	for _, c := range col.columns {
		// the column may be serialized using a different name due to a struct "targetStruct" tag
		sField, ok := getStructFieldValue(targetStruct, c.Name())
		// test if map
		if !ok {
			continue
		}
		switch dCol := c.(type) {
		case *Tuple:
			switch sField.Kind() {
			case reflect.Struct:
				if err := dCol.scanStruct(sField, row); err != nil {
					return err
				}
			case reflect.Map:
				newMap := reflect.MakeMap(sField.Type())
				if err := dCol.scanMap(newMap, row); err != nil {
					return err
				}
				sField.Set(newMap)
			case reflect.Interface:
				// catches []any -Note this swallows custom interfaces to which maps couldn't conform
				newMap := reflect.ValueOf(make(map[string]interface{}))
				if err := dCol.scanMap(newMap, row); err != nil {
					return err
				}
				sField.Set(newMap)
			default:
				return &Error{
					ColumnType: fmt.Sprint(sField.Kind()),
					Err:        fmt.Errorf("column %s - needs a map/struct/slice or any", col.Name()),
				}
			}
		case *Nested:
			aCol := dCol.Interface.(*Array)
			subSlice, err := aCol.scan(sField.Type(), row)
			if err != nil {
				return err
			}
			sField.Set(subSlice)
		case *Array:
			subSlice, err := dCol.scan(sField.Type(), row)
			if err != nil {
				return err
			}
			sField.Set(subSlice)
		default:
			value := reflect.ValueOf(c.Row(row, false))
			if err := setJSONFieldValue(sField, value); err != nil {
				return err
			}
		}
	}
	return nil
}

func (col *Tuple) scanSlice(targetType reflect.Type, row int) (reflect.Value, error) {
	rSlice := reflect.MakeSlice(targetType, 0, len(col.columns))
	for _, c := range col.columns {
		switch dCol := c.(type) {
		case *Tuple:
			value, err := dCol.scan(rSlice.Type().Elem(), row)
			if err != nil {
				return reflect.Value{}, err
			}
			rSlice = reflect.Append(rSlice, value)
		case *Nested:
			aCol := dCol.Interface.(*Array)
			subSlice, err := aCol.scan(rSlice.Type().Elem(), row)
			if err != nil {
				return reflect.Value{}, err
			}
			rSlice = reflect.Append(rSlice, subSlice)
		case *Array:
			subSlice, err := dCol.scan(rSlice.Type().Elem(), row)
			if err != nil {
				return reflect.Value{}, err
			}
			rSlice = reflect.Append(rSlice, subSlice)
		default:
			field := reflect.New(c.ScanType()).Elem()
			val := c.Row(row, false)
			if val != nil {
				value := reflect.ValueOf(val)
				if err := setJSONFieldValue(field, value); err != nil {
					return reflect.Value{}, err
				}
			}
			rSlice = reflect.Append(rSlice, field)
		}
	}
	return rSlice, nil
}

func (col *Tuple) scan(targetType reflect.Type, row int) (reflect.Value, error) {
	switch targetType.Kind() {
	case reflect.Struct:
		rStruct := reflect.New(targetType).Elem()
		err := col.scanStruct(rStruct, row)
		if err != nil {
			return reflect.Value{}, err
		}
		return rStruct, nil
	case reflect.Map:
		// if !col.isNamed {
		return reflect.Value{}, &ColumnConverterError{
			Op:   "ScanRow",
			To:   targetType.String(),
			From: string(col.chType),
			Hint: "cannot use maps for unnamed tuples, use slice",
		}
		// }
		// rMap := reflect.MakeMap(targetType)
		// if err := col.scanMap(rMap, row); err != nil {
		// 	return reflect.Value{}, nil
		// }
		// return rMap, nil
	case reflect.Slice:
		//tuples can be scanned into slices - specifically default for unnamed tuples
		rSlice, err := col.scanSlice(targetType, row)
		if err != nil {
			return reflect.Value{}, err
		}
		return rSlice, nil
	case reflect.Interface:
		// catches any -Note this swallows custom interfaces to which maps couldn't conform
		// if !col.isNamed {
		return reflect.Value{}, &ColumnConverterError{
			Op:   "ScanRow",
			To:   fmt.Sprintf("%s", targetType),
			From: string(col.chType),
			Hint: "cannot use interface for unnamed tuples, use slice",
		}
		// }
		// rMap := reflect.ValueOf(make(map[string]any))
		// if err := col.scanMap(rMap, row); err != nil {
		// 	return reflect.Value{}, err
		// }
		// return rMap, nil
	}
	return reflect.Value{}, &Error{
		ColumnType: fmt.Sprint(targetType.Kind()),
		Err:        fmt.Errorf("column %s - needs a map/struct/slice or any", col.Name()),
	}
}

func (col *Tuple) ScanRow(dest interface{}, row int) error {
	value := reflect.Indirect(reflect.ValueOf(dest))
	tuple, err := col.scan(value.Type(), row)
	if err != nil {
		return err
	}
	value.Set(tuple)
	return nil
}

func (col *Tuple) Append(v interface{}) (nulls []uint8, err error) {
	switch v := v.(type) {
	case [][]interface{}:
		for _, v := range v {
			if err := col.AppendRow(v); err != nil {
				return nil, err
			}
		}
		return nil, nil
	}
	return nil, &ColumnConverterError{
		Op:   "Append",
		To:   string(col.chType),
		From: fmt.Sprintf("%T", v),
	}
}

func (col *Tuple) AppendRow(v interface{}) error {
	switch v := v.(type) {
	case []interface{}:
		if len(v) != len(col.columns) {
			return &Error{
				ColumnType: string(col.chType),
				Err:        fmt.Errorf("invalid size. expected %d got %d", len(col.columns), len(v)),
			}
		}
		for i, v := range v {
			if err := col.columns[i].AppendRow(v); err != nil {
				return err
			}
		}
		return nil
	}
	return &ColumnConverterError{
		Op:   "AppendRow",
		To:   string(col.chType),
		From: fmt.Sprintf("%T", v),
	}
}

func (col *Tuple) Decode(decoder *binary.Decoder, rows int) error {
	for _, c := range col.columns {
		if err := c.Decode(decoder, rows); err != nil {
			return err
		}
	}
	return nil
}

func (col *Tuple) Encode(encoder *binary.Encoder) error {
	for _, c := range col.columns {
		if err := c.Encode(encoder); err != nil {
			return err
		}
	}
	return nil
}

func (col *Tuple) ReadStatePrefix(decoder *binary.Decoder) error {
	for _, c := range col.columns {
		if serialize, ok := c.(CustomSerialization); ok {
			if err := serialize.ReadStatePrefix(decoder); err != nil {
				return err
			}
		}
	}
	return nil
}

func (col *Tuple) WriteStatePrefix(encoder *binary.Encoder) error {
	for _, c := range col.columns {
		if serialize, ok := c.(CustomSerialization); ok {
			if err := serialize.WriteStatePrefix(encoder); err != nil {
				return err
			}
		}
	}
	return nil
}

var (
	_ Interface           = (*Tuple)(nil)
	_ CustomSerialization = (*Tuple)(nil)
)
