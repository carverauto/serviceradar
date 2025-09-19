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
	"fmt"
	"reflect"

	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
)

type Bool struct {
	values UInt8
	name   string
}

func (col *Bool) Name() string {
	return col.name
}

func (col *Bool) Type() Type {
	return "bool"
}

func (col *Bool) ScanType() reflect.Type {
	return scanTypeBool
}

func (col *Bool) Rows() int {
	return len(col.values.col)
}

func (col *Bool) Row(i int, ptr bool) interface{} {
	val := col.row(i)
	if ptr {
		return &val
	}
	return val
}

func (col *Bool) ScanRow(dest interface{}, row int) error {
	switch d := dest.(type) {
	case *bool:
		*d = col.row(row)
	case **bool:
		*d = new(bool)
		**d = col.row(row)
	default:
		return &ColumnConverterError{
			Op:   "ScanRow",
			To:   fmt.Sprintf("%T", dest),
			From: "bool",
		}
	}
	return nil
}

func (col *Bool) Append(v interface{}) (nulls []uint8, err error) {
	switch v := v.(type) {
	case []bool:
		in := make([]uint8, 0, len(v))
		for _, v := range v {
			switch {
			case v:
				in = append(in, 1)
			default:
				in = append(in, 0)
			}
		}
		col.values.col, nulls = append(col.values.col, in...), make([]uint8, len(v))
	case []*bool:
		nulls = make([]uint8, len(v))
		in := make([]uint8, 0, len(v))
		for i, v := range v {
			var value uint8
			switch {
			case v != nil:
				if *v {
					value = 1
				}
			default:
				nulls[i] = 1
			}
			in = append(in, value)
		}
		col.values.col = append(col.values.col, in...)
	default:
		return nil, &ColumnConverterError{
			Op:   "Append",
			To:   "bool",
			From: fmt.Sprintf("%T", v),
		}
	}
	return
}

func (col *Bool) AppendRow(v interface{}) error {
	var value bool
	switch v := v.(type) {
	case bool:
		value = v
	case *bool:
		if v != nil {
			value = *v
		}
	case nil:
	default:
		return &ColumnConverterError{
			Op:   "AppendRow",
			To:   "bool",
			From: fmt.Sprintf("%T", v),
		}
	}
	switch {
	case value:
		col.values.col = append(col.values.col, 1)
	default:
		col.values.col = append(col.values.col, 0)
	}
	return nil
}

func (col *Bool) Decode(decoder *binary.Decoder, rows int) error {
	return col.values.Decode(decoder, rows)
}

func (col *Bool) Encode(encoder *binary.Encoder) error {
	return col.values.Encode(encoder)
}

func (col *Bool) row(i int) bool {
	return col.values.col[i] == 1
}

var _ Interface = (*Bool)(nil)
