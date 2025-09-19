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
	"reflect"

	"github.com/timeplus-io/proton-go-driver/v2/lib/binary"
)

type SharedVariant struct {
	name       string
	stringData String
}

func (c *SharedVariant) Name() string {
	return c.name
}

func (c *SharedVariant) Type() Type {
	return "shared_variant"
}

func (c *SharedVariant) Rows() int {
	return c.stringData.Rows()
}

func (c *SharedVariant) Row(i int, ptr bool) interface{} {
	return c.stringData.Row(i, ptr)
}

func (c *SharedVariant) ScanRow(dest interface{}, row int) error {
	return c.stringData.ScanRow(dest, row)
}

func (c *SharedVariant) Append(v interface{}) (nulls []uint8, err error) {
	return c.stringData.Append(v)
}

func (c *SharedVariant) AppendRow(v interface{}) error {
	return c.stringData.AppendRow(v)
}

func (c *SharedVariant) Decode(decoder *binary.Decoder, rows int) error {
	return c.stringData.Decode(decoder, rows)
}

func (c *SharedVariant) Encode(encoder *binary.Encoder) error {
	return c.stringData.Encode(encoder)
}

func (c *SharedVariant) ScanType() reflect.Type {
	return c.stringData.ScanType()
}
