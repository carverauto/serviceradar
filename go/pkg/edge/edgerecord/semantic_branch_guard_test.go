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
	"os"
	"path/filepath"
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

	files := map[string]*ast.File{}

	for _, file := range []string{"semantic.go", "claims_framing.go"} {
		f, err := parser.ParseFile(fset, semFramerSourcePath(t, file), nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", file, err)
		}

		files[file] = f
	}

	// PASS ONE: which parameter of each framer is its PRESENCE FLAG. Collected from the sources
	// rather than listed, so a framer that gains one is covered without editing this test.
	boolParams := map[string][]int{}

	for _, f := range files {
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || !semIsFramerFunc(fn) {
				continue
			}

			idx := 0

			for _, field := range fn.Type.Params.List {
				id, isIdent := field.Type.(*ast.Ident)
				n := len(field.Names)

				if n == 0 {
					n = 1
				}

				for range n {
					if isIdent && id.Name == "bool" {
						boolParams[fn.Name.Name] = append(boolParams[fn.Name.Name], idx)
					}

					idx++
				}
			}
		}
	}

	for _, f := range files {
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
				case *ast.CallExpr:
					violations = append(violations, semCallViolations(fset, fn, stmt, flags, boolParams)...)
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

// semCallViolations is the ARGUMENT-PROVENANCE half of the guard.
//
// CONTROL-FLOW SYNTAX ALONE IS FAIL-OPEN, and this is the hole it left: a presence flag is
// COMPUTED AT THE CALL SITE and passed in, so
//
//	d.outputContract(c, c != nil && r.GetProjectedRowCount() != 42)
//
// contains no `if` at all. It passed the syntax check and the entire suite while making an
// admitted 42-row record frame its non-nil contract exactly like an absent one. A framer's
// presence argument must therefore satisfy the SAME predicate its own `if` would have to.
//
// AND THE CALLEE SURFACE IS CLOSED, because `d.outputContract(c, somePredicate(r))` moves the
// branch into a function this test never reads. Only digestWriter methods, proto getters, the
// digest constructor, and value conversions may be called from a framer -- anything else is a
// place for order to depend on a payload value out of sight.
func semCallViolations(fset *token.FileSet, fn *ast.FuncDecl, call *ast.CallExpr,
	flags map[string]bool, boolParams map[string][]int,
) []string {
	var out []string

	if !semAllowedCallee(call.Fun) {
		return append(out, semViolation(fset, fn, call,
			"calls something other than a digestWriter method, a proto getter or a conversion: "+
				"framing order must not depend on a function this guard cannot read"))
	}

	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return out
	}

	recv, ok := sel.X.(*ast.Ident)
	if !ok || recv.Name != "d" {
		return out
	}

	for _, i := range boolParams[sel.Sel.Name] {
		if i >= len(call.Args) {
			continue
		}

		if !semAllowedPresenceCond(call.Args[i], flags) {
			out = append(out, semViolation(fset, fn, call.Args[i],
				"presence argument to "+sel.Sel.Name+" is not a presence expression"))
		}
	}

	return out
}

// semAllowedCallee closes the call surface a framer may reach.
func semAllowedCallee(fun ast.Expr) bool {
	switch f := fun.(type) {
	case *ast.Ident:
		return semAllowedPlainCalls[f.Name]
	case *ast.ArrayType, *ast.InterfaceType:
		// a conversion such as []byte(s)
		return true
	case *ast.SelectorExpr:
		if id, ok := f.X.(*ast.Ident); ok && id.Name == "d" {
			return true
		}

		if strings.HasPrefix(f.Sel.Name, "Get") {
			return true
		}

		return semAllowedQualifiedCalls[semExprString(f)]
	case *ast.ParenExpr:
		return semAllowedCallee(f.X)
	}

	return false
}

// semAllowedPlainCalls and semAllowedQualifiedCalls are the ONLY non-framer, non-getter calls a
// framer may make. Widening either is a deliberate act.
var semAllowedPlainCalls = map[string]bool{
	"uint64": true, "int64": true, "uint32": true, "int32": true, "byte": true, "string": true,
	"len": true, "append": true, "newDigest": true,
	"semanticEnvelopeDigestWithVersion": true,
}

var semAllowedQualifiedCalls = map[string]bool{
	"sha256.Sum256":              true,
	"binary.BigEndian.PutUint64": true,
}

func semExprString(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.Ident:
		return x.Name
	case *ast.SelectorExpr:
		return semExprString(x.X) + "." + x.Sel.Name
	}

	return ""
}

// semFramerSourcePath finds a framer source under `go test` AND under Bazel.
//
// A GUARD THAT CANNOT OPEN ITS SUBJECT MUST FAIL, NOT SKIP. Under Bazel the working directory is
// the runfiles tree, not the package directory, so a bare relative path resolves to nothing --
// and a test that quietly found no files would report no violations, which is the same green as
// a clean tree. The candidates are tried in order and the last resort is a hard failure.
func semFramerSourcePath(t *testing.T, name string) string {
	t.Helper()

	candidates := []string{name}

	if dir := os.Getenv("TEST_SRCDIR"); dir != "" {
		wsp := os.Getenv("TEST_WORKSPACE")
		candidates = append(candidates,
			filepath.Join(dir, wsp, "go", "pkg", "edge", "edgerecord", name),
			filepath.Join(dir, "go", "pkg", "edge", "edgerecord", name),
		)
	}

	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}

	t.Fatalf("cannot locate framer source %s (tried %v); a guard that cannot read its subject "+
		"reports no violations, which is indistinguishable from a clean tree", name, candidates)

	return ""
}
