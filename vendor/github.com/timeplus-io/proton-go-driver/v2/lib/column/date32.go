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
	"time"

	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
	"github.com/timeplus-io/proton-go-driver/v2/types"
)

var (
	minDate32, _ = time.Parse("2006-01-02 15:04:05", "1925-01-01 00:00:00")
	maxDate32, _ = time.Parse("2006-01-02 15:04:05", "2283-11-11 00:00:00")
)

type Date32 struct {
	values   Int32
	name     string
	location *time.Location
}

func (col *Date32) Name() string {
	return col.name
}

func (dt *Date32) Type() Type {
	return "date32"
}

func (col *Date32) ScanType() reflect.Type {
	return scanTypeDate
}

func (dt *Date32) Rows() int {
	return len(dt.values.col)
}

func (dt *Date32) Row(i int, ptr bool) interface{} {
	value := dt.row(i)
	if ptr {
		return &value
	}
	return value
}

func (dt *Date32) ScanRow(dest interface{}, row int) error {
	switch d := dest.(type) {
	case *time.Time:
		*d = dt.row(row).Time
	case **time.Time:
		*d = new(time.Time)
		**d = dt.row(row).Time
	case *types.Date:
		*d = dt.row(row)
	case **types.Date:
		*d = new(types.Date)
		**d = dt.row(row)
	default:
		return &ColumnConverterError{
			Op:   "ScanRow",
			To:   fmt.Sprintf("%T", dest),
			From: "date32",
		}
	}
	return nil
}

func (dt *Date32) Append(v interface{}) (nulls []uint8, err error) {
	switch v := v.(type) {
	case []time.Time:
		in := make([]int32, 0, len(v))
		for _, t := range v {
			if err := dateOverflow(minDate32, maxDate32, t, "2006-01-02"); err != nil {
				return nil, err
			}
			in = append(in, timeToInt32(t))
		}
		dt.values.col, nulls = append(dt.values.col, in...), make([]uint8, len(v))
	case []*time.Time:
		nulls = make([]uint8, len(v))
		for i, v := range v {
			switch {
			case v != nil:
				if err := dateOverflow(minDate32, maxDate32, *v, "2006-01-02"); err != nil {
					return nil, err
				}
				dt.values.col = append(dt.values.col, timeToInt32(*v))
			default:
				dt.values.col, nulls[i] = append(dt.values.col, 0), 1
			}
		}
	case []types.Date:
		in := make([]int32, 0, len(v))
		for _, t := range v {
			if err := dateOverflow(minDate32, maxDate32, t.Time, "2006-01-02"); err != nil {
				return nil, err
			}
			in = append(in, timeToInt32(t.Time))
		}
		dt.values.col, nulls = append(dt.values.col, in...), make([]uint8, len(v))
	case []*types.Date:
		nulls = make([]uint8, len(v))
		for i, v := range v {
			switch {
			case v != nil:
				if err := dateOverflow(minDate32, maxDate32, (*v).Time, "2006-01-02"); err != nil {
					return nil, err
				}
				dt.values.col = append(dt.values.col, timeToInt32((*v).Time))
			default:
				dt.values.col, nulls[i] = append(dt.values.col, 0), 1
			}
		}
	default:
		return nil, &ColumnConverterError{
			Op:   "Append",
			To:   "date32",
			From: fmt.Sprintf("%T", v),
		}
	}
	return
}

func (dt *Date32) AppendRow(v interface{}) error {
	var date int32
	switch v := v.(type) {
	case time.Time:
		if err := dateOverflow(minDate32, maxDate32, v, "2006-01-02"); err != nil {
			return err
		}
		date = timeToInt32(v)
	case *time.Time:
		if v != nil {
			if err := dateOverflow(minDate32, maxDate32, *v, "2006-01-02"); err != nil {
				return err
			}
			date = timeToInt32(*v)
		}
	case types.Date:
		if err := dateOverflow(minDate32, maxDate32, v.Time, "2006-01-02"); err != nil {
			return err
		}
		date = timeToInt32(v.Time)
	case *types.Date:
		if v != nil {
			if err := dateOverflow(minDate32, maxDate32, (*v).Time, "2006-01-02"); err != nil {
				return err
			}
			date = timeToInt32((*v).Time)
		}
	case nil:
	default:
		return &ColumnConverterError{
			Op:   "AppendRow",
			To:   "date32",
			From: fmt.Sprintf("%T", v),
		}
	}
	dt.values.col = append(dt.values.col, date)
	return nil
}

func (dt *Date32) Decode(decoder *binary.Decoder, rows int) error {
	return dt.values.Decode(decoder, rows)
}

func (dt *Date32) Encode(encoder *binary.Encoder) error {
	return dt.values.Encode(encoder)
}

func (dt *Date32) row(i int) types.Date {
	return types.Date{Time: time.Unix((int64(dt.values.col[i]) * secInDay), 0).UTC()}
}

func timeToInt32(t time.Time) int32 {
	return int32(t.Unix() / secInDay)
}

var _ Interface = (*Date32)(nil)
