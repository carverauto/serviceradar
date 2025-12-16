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

// Package snmp pkg/checker/snmp/service_deadlock_test.go
package snmp

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"runtime"
	"testing"
)

func TestCheckDoesNotRLockAndCallGetStatus(t *testing.T) {
	t.Helper()

	fileSet := token.NewFileSet()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("unable to locate test file path via runtime.Caller")
	}
	filePath := filepath.Join(filepath.Dir(thisFile), "service.go")
	parsed, err := parser.ParseFile(fileSet, filePath, nil, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", filePath, err)
	}

	var checkDecl *ast.FuncDecl
	for _, decl := range parsed.Decls {
		funcDecl, ok := decl.(*ast.FuncDecl)
		if !ok || funcDecl.Recv == nil || funcDecl.Name == nil {
			continue
		}
		if funcDecl.Name.Name == "Check" {
			checkDecl = funcDecl
			break
		}
	}

	if checkDecl == nil || checkDecl.Body == nil || len(checkDecl.Recv.List) == 0 {
		t.Fatalf("Check method not found in %s", filePath)
	}

	if len(checkDecl.Recv.List[0].Names) == 0 || checkDecl.Recv.List[0].Names[0] == nil || checkDecl.Recv.List[0].Names[0].Name == "" {
		t.Fatalf("unable to determine Check receiver identifier in %s", filePath)
	}
	receiverName := checkDecl.Recv.List[0].Names[0].Name

	var hasMuRLock bool
	var hasGetStatusCall bool

	ast.Inspect(checkDecl.Body, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}

		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || selector.Sel == nil {
			return true
		}

		if selector.Sel.Name == "GetStatus" {
			if recv, ok := selector.X.(*ast.Ident); ok && recv.Name == receiverName {
				hasGetStatusCall = true
			}
			return true
		}

		if selector.Sel.Name != "RLock" {
			return true
		}

		muSelector, ok := selector.X.(*ast.SelectorExpr)
		if !ok || muSelector.Sel == nil || muSelector.Sel.Name != "mu" {
			return true
		}

		if recv, ok := muSelector.X.(*ast.Ident); ok && recv.Name == receiverName {
			hasMuRLock = true
		}

		return true
	})

	if hasMuRLock && hasGetStatusCall {
		t.Fatalf("Check must not call GetStatus while holding s.mu.RLock (recursive RWMutex read locking can deadlock)")
	}
}
