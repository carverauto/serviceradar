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
// SO THE MATRIX IS ENUMERATED FROM THE DECLARED AXES rather than chosen, and this test checks
// that the framers keep the shape that enumeration assumes: control flow may branch ONLY on
// carrier presence and oneof discriminants, nothing may branch on a payload VALUE, and the write
// sequence may not be SELECTED from data.
//
// IT IS DEFENSE IN DEPTH, NOT WHAT MAKES THE MATRIX COMPLETE, and the difference matters because
// it has known holes. It identifies proto and oneof accessors BY NAME, so a method spelled
// `GetClaims` on an unrelated type is accepted; it reasons about SYNTAX rather than types. The
// committed cross product is therefore exhaustive over the DECLARED axes -- not over every Go
// program -- and this test narrows what can drift there without proving nothing can.
//
// Closing it properly needs a descriptor-validated declarative grammar that GENERATES the
// framers, which removes the arbitrary host program instead of analysing it. Recorded as an
// unowned follow-up in design.md -- no identifier, no owner, nothing blocked on it -- and
// deliberately not attempted here.
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
					violations = append(violations,
						semCallViolations(fset, fn, stmt, flags, boolParams, semWriterName(fn))...)
				case *ast.IndexExpr:
					// BRANCHLESS SELECTION IS STILL SELECTION. `map[bool][2]uint64{...}[x == 42]`
					// reorders two writes with no `if` anywhere, and a control-flow blacklist
					// cannot see it -- measured, it passed the whole package.
					violations = append(violations, semViolation(fset, fn, stmt,
						"index/map lookup: the write sequence may not be SELECTED from data"))
				case *ast.FuncLit:
					violations = append(violations, semViolation(fset, fn, stmt,
						"function literal: framing order must not route through a closure"))
				case *ast.CompositeLit:
					if _, isMap := stmt.Type.(*ast.MapType); isMap {
						violations = append(violations, semViolation(fset, fn, stmt,
							"map literal: the write sequence may not be selected from data"))
					}
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

// semIsFramerFunc covers EVERY function declared in the two grammar files.
//
// SPELLING-BASED DISCOVERY WAS A BYPASS. Scoping to `*digestWriter` methods missed the root,
// which is a plain function; scoping to "calls something spelled `d`" missed a framer whose
// receiver is renamed, and missed the exported wrapper entirely. These two files ARE the grammar,
// so every function in them is in scope and nothing is admitted by how it happens to be written.
func semIsFramerFunc(fn *ast.FuncDecl) bool {
	return fn.Body != nil
}

// semReceiverName is the framer's own receiver variable, whatever it is called. Matching the
// literal `d` meant renaming the receiver silently left the call checks unenforced.
func semReceiverName(fn *ast.FuncDecl) string {
	if fn.Recv == nil || len(fn.Recv.List) != 1 || len(fn.Recv.List[0].Names) != 1 {
		return ""
	}

	star, ok := fn.Recv.List[0].Type.(*ast.StarExpr)
	if !ok {
		return ""
	}

	id, ok := star.X.(*ast.Ident)
	if !ok || id.Name != "digestWriter" {
		return ""
	}

	return fn.Recv.List[0].Names[0].Name
}

// semWriterName is the digestWriter a function drives: its receiver if it is a method, otherwise
// the local it constructs with `newDigest()`. The root framer is a plain function, so without
// this its calls read as reaching outside the closed surface.
func semWriterName(fn *ast.FuncDecl) string {
	if n := semReceiverName(fn); n != "" {
		return n
	}

	name := ""

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok || len(as.Lhs) != 1 || len(as.Rhs) != 1 {
			return true
		}

		call, ok := as.Rhs[0].(*ast.CallExpr)
		if !ok {
			return true
		}

		if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "newDigest" {
			if lhs, ok := as.Lhs[0].(*ast.Ident); ok {
				name = lhs.Name
			}
		}

		return true
	})

	return name
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
		//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
		switch x.Op {
		case token.LAND, token.LOR:
			return semAllowedPresenceCond(x.X, flags) && semAllowedPresenceCond(x.Y, flags)
		case token.EQL, token.NEQ:
			return semIsNilLit(x.Y) || semIsNilLit(x.X)
		default:
			// Fail closed: every other operator (<, >, arithmetic comparison) can select on a
			// VALUE, which is exactly what this guard exists to reject.
			return false
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
//
//nolint:gochecknoglobals // immutable accessor allowlist
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
// AND THE CALLEE SURFACE IS NARROWED, because `d.outputContract(c, somePredicate(r))` moves the
// branch into a function this test never reads. A framer may call digestWriter methods, the
// digest constructor, value conversions, and accessors -- anything else is a place for order to
// depend on a payload value out of sight.
//
// NARROWED, NOT CLOSED. "Accessor" here means ANY selector whose name begins with `Get`, matched
// by SPELLING: a method called `GetAnything` on an unrelated type is accepted, and so is a
// hand-written one. Closing that needs type identity, which this syntax-level check does not
// have -- see the limits on the test above.
func semCallViolations(fset *token.FileSet, fn *ast.FuncDecl, call *ast.CallExpr,
	flags map[string]bool, boolParams map[string][]int, recvName string,
) []string {
	var out []string

	if !semAllowedCallee(call.Fun, recvName) {
		return append(out, semViolation(fset, fn, call,
			"calls something other than a digestWriter method, a `Get*`-spelled selector or a "+
				"conversion: framing order must not depend on a function this guard cannot read"))
	}

	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return out
	}

	recv, ok := sel.X.(*ast.Ident)
	if !ok || recv.Name == "" || recv.Name != recvName {
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

// semAllowedCallee NARROWS the call surface a framer may reach. It does not close it: the
// accessor arm matches any selector SPELLED `Get*`, on any receiver, so a hand-written method of
// that name passes. Identity would need types, which this syntax-level check does not have.
func semAllowedCallee(fun ast.Expr, recvName string) bool {
	switch f := fun.(type) {
	case *ast.Ident:
		return semAllowedPlainCalls[f.Name]
	case *ast.ArrayType, *ast.InterfaceType:
		// a conversion such as []byte(s)
		return true
	case *ast.SelectorExpr:
		if id, ok := f.X.(*ast.Ident); ok && recvName != "" && id.Name == recvName {
			return true
		}

		if strings.HasPrefix(f.Sel.Name, "Get") {
			return true
		}

		return semAllowedQualifiedCalls[semExprString(f)]
	case *ast.ParenExpr:
		return semAllowedCallee(f.X, recvName)
	}

	return false
}

// semAllowedPlainCalls and semAllowedQualifiedCalls are the ONLY non-framer, non-getter calls a
// framer may make. Widening either is a deliberate act.
//
//nolint:gochecknoglobals // immutable call allowlist
var semAllowedPlainCalls = map[string]bool{
	"uint64": true, "int64": true, "uint32": true, "int32": true, "byte": true, "string": true,
	"len": true, "append": true, "newDigest": true,
	"semanticEnvelopeDigestWithVersion": true,
}

//nolint:gochecknoglobals // immutable call allowlist
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
