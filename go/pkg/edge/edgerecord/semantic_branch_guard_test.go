/*
 * Copyright 2026 Carver Automation Corporation.
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

package edgerecord

import (
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"strings"
	"testing"
)

// THE STATIC GUARD. Everything else in the semantic-envelope suite is FINITE EVIDENCE, and finite
// evidence over a grammar that may branch on arbitrary payload values can always be evaded by one
// more unmodeled predicate. Five rounds of review demonstrated exactly that: each survivor was a
// reordering conditioned on some state no committed fixture happened to hold -- a claims variant,
// then a carrier, then a PAIR of carriers, then a pair the fixtures held but the guard compared
// globally. Extending the matrix each time does not converge, because the space of predicates a
// framer COULD branch on is unbounded.
//
// SO BOUND IT. This test reads the framer sources and asserts that their control flow branches
// ONLY on the declared structural axes -- carrier presence, and oneof discriminants. Nothing may
// branch on a payload VALUE. With that established, the axes are finite and enumerable, and the
// cross product of their states is COMPLETE coverage rather than another hand-picked matrix.
//
// The two halves are load-bearing together and worth little apart: this guard says "the code
// cannot branch on anything else", and the shape enumeration says "every combination of what it
// CAN branch on is committed".
func TestSemanticFramingBranchesOnlyOnDeclaredAxes(t *testing.T) {
	fset := token.NewFileSet()

	var violations []string

	for _, file := range []string{"semantic.go", "claims_framing.go"} {
		f, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", file, err)
		}

		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || !semIsFramerFunc(fn) {
				continue
			}

			flags := semBoolParams(fn)

			ast.Inspect(fn.Body, func(n ast.Node) bool {
				switch stmt := n.(type) {
				case *ast.IfStmt:
					if !semAllowedPresenceCond(stmt.Cond, flags) {
						violations = append(violations, semViolation(fset, fn, stmt.Cond,
							"if-condition is not a presence check"))
					}
				case *ast.TypeSwitchStmt:
					if !semAllowedDiscriminantSwitch(stmt) {
						violations = append(violations, semViolation(fset, fn, stmt,
							"type switch is not on a oneof accessor"))
					}
				case *ast.SwitchStmt:
					violations = append(violations, semViolation(fset, fn, stmt,
						"value switch: framing order may not depend on a payload value"))
				case *ast.ForStmt, *ast.RangeStmt:
					violations = append(violations, semViolation(fset, fn, stmt,
						"loop: the write sequence must be straight-line"))
				}

				return true
			})
		}
	}

	if len(violations) > 0 {
		sort.Strings(violations)
		t.Fatalf("%d framer branches are outside the declared structural axes. Framing order may "+
			"depend ONLY on carrier presence and oneof discriminants -- anything else is a "+
			"predicate no finite set of committed vectors can be complete against:\n  %s",
			len(violations), strings.Join(violations, "\n  "))
	}
}

// semIsFramerFunc covers EVERY function in these two files that emits transcript, not just the
// `*digestWriter` methods.
//
// SCOPING IT TO METHODS MISSED THE ROOT. `semanticEnvelopeDigestWithVersion` is a plain function
// and it is the primary framer -- the one that writes the version prefix, every direct slot and
// every carrier's presence decision. Measured: with the guard scoped to methods, adding
// `if r.GetEncodedSize() > 1000` to the ROOT passed it.
func semIsFramerFunc(fn *ast.FuncDecl) bool {
	if fn.Body == nil {
		return false
	}

	if fn.Recv != nil {
		if len(fn.Recv.List) != 1 {
			return false
		}

		star, ok := fn.Recv.List[0].Type.(*ast.StarExpr)
		if !ok {
			return false
		}

		id, ok := star.X.(*ast.Ident)

		return ok && id.Name == "digestWriter"
	}

	// A package-level function counts when it drives a digestWriter.
	found := false

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				if id, ok := sel.X.(*ast.Ident); ok && id.Name == "d" {
					found = true
				}
			}
		}

		return true
	})

	return found
}

// semBoolParams collects a framer's own bool parameters. Those ARE the presence axis: the caller
// decides presence and passes it in, which is precisely why the root's `c != nil` inference needed
// its own committed witnesses.
func semBoolParams(fn *ast.FuncDecl) map[string]bool {
	out := map[string]bool{}

	for _, field := range fn.Type.Params.List {
		id, ok := field.Type.(*ast.Ident)
		if !ok || id.Name != "bool" {
			continue
		}

		for _, name := range field.Names {
			out[name.Name] = true
		}
	}

	return out
}

// semAllowedPresenceCond accepts only nil-comparisons and the framer's own presence flags, plus
// conjunctions and disjunctions of those: `c == nil`, `!present`, `!present || c == nil`,
// `p.AuthorityEpoch != nil`.
func semAllowedPresenceCond(e ast.Expr, flags map[string]bool) bool {
	switch x := e.(type) {
	case *ast.ParenExpr:
		return semAllowedPresenceCond(x.X, flags)
	case *ast.UnaryExpr:
		return x.Op == token.NOT && semAllowedPresenceCond(x.X, flags)
	case *ast.Ident:
		return flags[x.Name]
	case *ast.BinaryExpr:
		switch x.Op {
		case token.LAND, token.LOR:
			return semAllowedPresenceCond(x.X, flags) && semAllowedPresenceCond(x.Y, flags)
		case token.EQL, token.NEQ:
			return semIsNilLit(x.Y) || semIsNilLit(x.X)
		}
	}

	return false
}

func semIsNilLit(e ast.Expr) bool {
	id, ok := e.(*ast.Ident)

	return ok && id.Name == "nil"
}

// semAllowedDiscriminantSwitch accepts a type switch whose subject is a oneof accessor -- the
// ONLY value-dependent branch the grammar is allowed, and the one every discriminant vector pins.
func semAllowedDiscriminantSwitch(stmt *ast.TypeSwitchStmt) bool {
	var assign ast.Node = stmt.Assign

	switch a := assign.(type) {
	case *ast.AssignStmt:
		if len(a.Rhs) != 1 {
			return false
		}

		ta, ok := a.Rhs[0].(*ast.TypeAssertExpr)
		if !ok {
			return false
		}

		return semIsOneofAccessor(ta.X)
	case *ast.ExprStmt:
		ta, ok := a.X.(*ast.TypeAssertExpr)
		if !ok {
			return false
		}

		return semIsOneofAccessor(ta.X)
	}

	return false
}

func semIsOneofAccessor(e ast.Expr) bool {
	call, ok := e.(*ast.CallExpr)
	if !ok {
		return false
	}

	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}

	return semOneofAccessors[sel.Sel.Name]
}

// semOneofAccessors NAMES the oneof axes. Adding one here is a deliberate act: it widens what the
// grammar may branch on, and the shape enumeration must gain the corresponding axis.
var semOneofAccessors = map[string]bool{
	"GetClaims":     true,
	"GetTransition": true,
}

func semViolation(fset *token.FileSet, fn *ast.FuncDecl, n ast.Node, why string) string {
	pos := fset.Position(n.Pos())

	return fn.Name.Name + " at " + pos.String() + ": " + why
}
