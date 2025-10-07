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
	"math"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2/types"

	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
	"github.com/timeplus-io/proton-go-driver/v2/lib/timezone"
)

var (
	minDateTime64, _ = time.Parse("2006-01-02 15:04:05", "1925-01-01 00:00:00")
	maxDateTime64, _ = time.Parse("2006-01-02 15:04:05", "2283-11-11 00:00:00")
)

type DateTime64 struct {
	chType    Type
	values    Int64
	timezone  *time.Location
	name      string
	precision int
}

func (col *DateTime64) Name() string {
	return col.name
}

func (dt *DateTime64) parse(t Type, tz *time.Location) (_ Interface, err error) {
	dt.chType = t
	switch params := strings.Split(t.params(), ","); len(params) {
	case 2:
		if dt.precision, err = strconv.Atoi(params[0]); err != nil {
			return nil, err
		}
		if dt.timezone, err = timezone.Load(params[1][2 : len(params[1])-1]); err != nil {
			return nil, err
		}
	case 1:
		if dt.precision, err = strconv.Atoi(params[0]); err != nil {
			return nil, err
		}
		dt.timezone = tz
	default:
		return nil, &UnsupportedColumnTypeError{
			t: t,
		}
	}
	return dt, nil
}

func (dt *DateTime64) Type() Type {
	return dt.chType
}

func (col *DateTime64) ScanType() reflect.Type {
	return scanTypeTime
}

func (dt *DateTime64) Rows() int {
	return len(dt.values.col)
}

func (dt *DateTime64) Row(i int, ptr bool) interface{} {
	value := dt.row(i)
	if ptr {
		return &value
	}
	return value
}

func (dt *DateTime64) ScanRow(dest interface{}, row int) error {
	switch d := dest.(type) {
	case *time.Time:
		*d = dt.row(row)
	case **time.Time:
		*d = new(time.Time)
		**d = dt.row(row)
	case *types.Datetime:
		*d = types.Datetime{dt.row(row)}
	case **types.Datetime:
		*d = new(types.Datetime)
		**d = types.Datetime{dt.row(row)}
	default:
		return &ColumnConverterError{
			Op:   "ScanRow",
			To:   fmt.Sprintf("%T", dest),
			From: "datetime64",
		}
	}
	return nil
}

func (dt *DateTime64) Append(v interface{}) (nulls []uint8, err error) {
	switch v := v.(type) {
	case []int64:
		dt.values.col, nulls = append(dt.values.col, v...), make([]uint8, len(v))
	case []time.Time:
		in := make([]int64, 0, len(v))
		for _, t := range v {
			if err := dateOverflow(minDateTime64, maxDateTime64, t, "2006-01-02 15:04:05"); err != nil {
				return nil, err
			}
			in = append(in, dt.timeToInt64(t))
		}
		dt.values.col, nulls = append(dt.values.col, in...), make([]uint8, len(v))
	case []*time.Time:
		nulls = make([]uint8, len(v))
		for i, v := range v {
			switch {
			case v != nil:
				if err := dateOverflow(minDateTime64, maxDateTime64, *v, "2006-01-02 15:04:05"); err != nil {
					return nil, err
				}
				dt.values.col = append(dt.values.col, dt.timeToInt64(*v))
			default:
				dt.values.col, nulls[i] = append(dt.values.col, 0), 1
			}
		}
	case []types.Datetime:
		in := make([]int64, 0, len(v))
		for _, t := range v {
			if err := dateOverflow(minDateTime64, maxDateTime64, t.Time, "2006-01-02 15:04:05"); err != nil {
				return nil, err
			}
			in = append(in, dt.timeToInt64(t.Time))
		}
		dt.values.col, nulls = append(dt.values.col, in...), make([]uint8, len(v))
	case []*types.Datetime:
		nulls = make([]uint8, len(v))
		for i, v := range v {
			switch {
			case v != nil:
				if err := dateOverflow(minDateTime64, maxDateTime64, (*v).Time, "2006-01-02 15:04:05"); err != nil {
					return nil, err
				}
				dt.values.col = append(dt.values.col, dt.timeToInt64((*v).Time))
			default:
				dt.values.col, nulls[i] = append(dt.values.col, 0), 1
			}
		}
	default:
		return nil, &ColumnConverterError{
			Op:   "Append",
			To:   "datetime64",
			From: fmt.Sprintf("%T", v),
		}
	}
	return
}

func (dt *DateTime64) AppendRow(v interface{}) error {
	var datetime int64
	switch v := v.(type) {
	case int64:
		datetime = v
	case time.Time:
		if err := dateOverflow(minDateTime64, maxDateTime64, v, "2006-01-02 15:04:05"); err != nil {
			return err
		}
		datetime = dt.timeToInt64(v)
	case *time.Time:
		if v != nil {
			if err := dateOverflow(minDateTime64, maxDateTime64, *v, "2006-01-02 15:04:05"); err != nil {
				return err
			}
			datetime = dt.timeToInt64(*v)
		}
	case types.Datetime:
		if err := dateOverflow(minDateTime64, maxDateTime64, v.Time, "2006-01-02 15:04:05"); err != nil {
			return err
		}
		datetime = dt.timeToInt64(v.Time)
	case *types.Datetime:
		if v != nil {
			if err := dateOverflow(minDateTime64, maxDateTime64, (*v).Time, "2006-01-02 15:04:05"); err != nil {
				return err
			}
			datetime = dt.timeToInt64((*v).Time)
		}
	case nil:
	default:
		return &ColumnConverterError{
			Op:   "AppendRow",
			To:   "datetime64",
			From: fmt.Sprintf("%T", v),
		}
	}
	dt.values.col = append(dt.values.col, datetime)
	return nil
}

func (dt *DateTime64) Decode(decoder *binary.Decoder, rows int) error {
	return dt.values.Decode(decoder, rows)
}

func (dt *DateTime64) Encode(encoder *binary.Encoder) error {
	return dt.values.Encode(encoder)
}

func (dt *DateTime64) row(i int) time.Time {
	var nano int64
	if dt.precision < 19 {
		nano = dt.values.col[i] * int64(math.Pow10(9-dt.precision))
	}
	var (
		sec  = nano / int64(10e8)
		nsec = nano - sec*10e8
		time = time.Unix(sec, nsec)
	)
	if dt.timezone != nil {
		time = time.In(dt.timezone)
	}
	return time
}

func (dt *DateTime64) timeToInt64(t time.Time) int64 {
	var timestamp int64
	if !t.IsZero() {
		timestamp = t.UnixNano()
	}
	return timestamp / int64(math.Pow10(9-dt.precision))
}

var _ Interface = (*DateTime64)(nil)
