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
	"encoding/json"
	"fmt"
	"reflect"

	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
)

type String struct {
	name string
	col  []string
}

func (col String) Name() string {
	return col.name
}

func (String) Type() Type {
	return "string"
}

func (String) ScanType() reflect.Type {
	return scanTypeString
}

func (col *String) Rows() int {
	return len(col.col)
}

func (col *String) Row(i int, ptr bool) interface{} {
	val := col.col[i]
	if ptr {
		return &val
	}
	return val
}

func (col *String) ScanRow(dest interface{}, row int) error {
	v := col.col
	switch d := dest.(type) {
	case *string:
		*d = v[row]
	case **string:
		*d = new(string)
		**d = v[row]
	case *json.RawMessage:
		*d = json.RawMessage(v[row])
	case **json.RawMessage:
		*d = new(json.RawMessage)
		**d = json.RawMessage(v[row])
	default:
		return &ColumnConverterError{
			Op:   "ScanRow",
			To:   fmt.Sprintf("%T", dest),
			From: "string",
		}
	}
	return nil
}

func (col *String) AppendRow(v interface{}) error {
	switch v := v.(type) {
	case string:
		col.col = append(col.col, v)
	case *string:
		switch {
		case v != nil:
			col.col = append(col.col, *v)
		default:
			col.col = append(col.col, "")
		}
	case json.RawMessage:
		col.col = append(col.col, string(v))
	case *json.RawMessage:
		col.col = append(col.col, string(*v))
	case nil:
		col.col = append(col.col, "")
	default:
		return &ColumnConverterError{
			Op:   "AppendRow",
			To:   "string",
			From: fmt.Sprintf("%T", v),
		}
	}
	return nil
}

func (col *String) Append(v interface{}) (nulls []uint8, err error) {
	switch v := v.(type) {
	case []string:
		col.col, nulls = append(col.col, v...), make([]uint8, len(v))
	case []*string:
		nulls = make([]uint8, len(v))
		for i, v := range v {
			switch {
			case v != nil:
				col.col = append(col.col, *v)
			default:
				col.col, nulls[i] = append(col.col, ""), 1
			}
		}
	case []json.RawMessage:
		nulls = make([]uint8, len(v))
		for i := range v {
			col.col = append(col.col, string(v[i]))
		}
	case []*json.RawMessage:
		nulls = make([]uint8, len(v))
		for i := range v {
			col.col = append(col.col, string(*v[i]))
		}
	default:
		return nil, &ColumnConverterError{
			Op:   "Append",
			To:   "string",
			From: fmt.Sprintf("%T", v),
		}
	}
	return
}

func (col *String) Decode(decoder *binary.Decoder, rows int) error {
	for i := 0; i < int(rows); i++ {
		v, err := decoder.String()
		if err != nil {
			return err
		}
		col.col = append(col.col, v)
	}
	return nil
}

func (col *String) Encode(encoder *binary.Encoder) error {
	for _, v := range col.col {
		if err := encoder.String(v); err != nil {
			return err
		}
	}
	return nil
}

var _ Interface = (*String)(nil)
