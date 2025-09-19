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

package proton

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2/contributors"
	"github.com/timeplus-io/proton-go-driver/v2/lib/column"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
	"github.com/timeplus-io/proton-go-driver/v2/lib/proto"
)

type Conn = driver.Conn

type (
	Progress      = proto.Progress
	Exception     = proto.Exception
	ProfileInfo   = proto.ProfileInfo
	ServerVersion = proto.ServerHandshake
)

var (
	ErrBatchAlreadySent               = errors.New("proton: batch has already been sent")
	ErrAcquireConnTimeout             = errors.New("proton: acquire conn timeout. you can increase the number of max open conn or the dial timeout")
	ErrUnsupportedServerRevision      = errors.New("proton: unsupported server revision")
	ErrBindMixedNamedAndNumericParams = errors.New("proton [bind]: mixed named and numeric parameters")
)

type OpError struct {
	Op         string
	ColumnName string
	Err        error
}

func (e *OpError) Error() string {
	switch err := e.Err.(type) {
	case *column.Error:
		return fmt.Sprintf("proton [%s]: (%s %s) %s", e.Op, e.ColumnName, err.ColumnType, err.Err)
	case *column.ColumnConverterError:
		var hint string
		if len(err.Hint) != 0 {
			hint += ". " + err.Hint
		}
		return fmt.Sprintf("proton [%s]: (%s) converting %s to %s is unsupported%s",
			err.Op, e.ColumnName,
			err.From, err.To,
			hint,
		)
	}
	return fmt.Sprintf("proton [%s]: %s", e.Op, e.Err)
}

func Open(opt *Options) (driver.Conn, error) {
	opt.setDefaults()
	return &proton{
		opt:  opt,
		idle: make(chan *connect, opt.MaxIdleConns),
		open: make(chan struct{}, opt.MaxOpenConns),
	}, nil
}

type proton struct {
	opt    *Options
	idle   chan *connect
	open   chan struct{}
	connID int64
}

func (proton) Contributors() []string {
	list := contributors.List
	if len(list[len(list)-1]) == 0 {
		return list[:len(list)-1]
	}
	return list
}

func (ch *proton) ServerVersion() (*driver.ServerVersion, error) {
	var (
		ctx, cancel = context.WithTimeout(context.Background(), ch.opt.DialTimeout)
		conn, err   = ch.acquire(ctx)
	)
	defer cancel()
	if err != nil {
		return nil, err
	}
	ch.release(conn, nil)
	return &conn.server, nil
}

func (ch *proton) Query(ctx context.Context, query string, args ...interface{}) (rows driver.Rows, err error) {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return nil, err
	}
	return conn.query(ctx, ch.release, query, args...)
}

func (ch *proton) QueryRow(ctx context.Context, query string, args ...interface{}) (rows driver.Row) {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return &row{
			err: err,
		}
	}
	return conn.queryRow(ctx, ch.release, query, args...)
}

func (ch *proton) Exec(ctx context.Context, query string, args ...interface{}) error {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return err
	}
	if err := conn.exec(ctx, query, args...); err != nil {
		ch.release(conn, err)
		return err
	}
	ch.release(conn, nil)
	return nil
}

func (ch *proton) PrepareBatch(ctx context.Context, query string) (driver.Batch, error) {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return nil, err
	}
	return conn.prepareBatch(ctx, query, ch.release)
}

func (ch *proton) AsyncInsert(ctx context.Context, query string, wait bool) error {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return err
	}
	if err := conn.asyncInsert(ctx, query, wait); err != nil {
		ch.release(conn, err)
		return err
	}
	ch.release(conn, nil)
	return nil
}

func (ch *proton) Ping(ctx context.Context) (err error) {
	conn, err := ch.acquire(ctx)
	if err != nil {
		return err
	}
	if err := conn.ping(ctx); err != nil {
		ch.release(conn, err)
		return err
	}
	ch.release(conn, nil)
	return nil
}

func (ch *proton) Stats() driver.Stats {
	return driver.Stats{
		Open:         len(ch.open),
		Idle:         len(ch.idle),
		MaxOpenConns: cap(ch.open),
		MaxIdleConns: cap(ch.idle),
	}
}

func (ch *proton) dial(ctx context.Context) (conn *connect, err error) {
	connID := int(atomic.AddInt64(&ch.connID, 1))
	for num := range ch.opt.Addr {
		if ch.opt.ConnOpenStrategy == ConnOpenRoundRobin {
			num = int(connID) % len(ch.opt.Addr)
		}
		if conn, err = dial(ctx, ch.opt.Addr[num], connID, ch.opt); err == nil {
			return conn, nil
		}
	}
	return nil, err
}

func (ch *proton) acquire(ctx context.Context) (conn *connect, err error) {
	timer := time.NewTimer(ch.opt.DialTimeout)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}
	select {
	case <-timer.C:
		return nil, ErrAcquireConnTimeout
	case ch.open <- struct{}{}:
	}
	select {
	case <-timer.C:
		return nil, ErrAcquireConnTimeout
	case conn := <-ch.idle:
		if conn.isBad() {
			conn.close()
			if conn, err = ch.dial(ctx); err != nil {
				select {
				case <-ch.open:
				default:
				}
				return nil, err
			}
		}
		conn.released = false
		return conn, nil
	default:
	}
	if conn, err = ch.dial(ctx); err != nil {
		select {
		case <-ch.open:
		default:
		}
		return nil, err
	}
	return conn, nil
}

func (ch *proton) release(conn *connect, err error) {
	if conn.released {
		return
	}
	conn.released = true
	select {
	case <-ch.open:
	default:
	}
	if err != nil || time.Since(conn.connectedAt) >= ch.opt.ConnMaxLifetime {
		conn.close()
		return
	}
	select {
	case ch.idle <- conn:
	default:
		conn.close()
	}
}

func (ch *proton) Close() error {
	for {
		select {
		case c := <-ch.idle:
			c.close()
		default:
			return nil
		}
	}
}
