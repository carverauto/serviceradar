package mcp

import "fmt"

type srqlBindBuilder struct {
	params []any
}

func (b *srqlBindBuilder) Bind(value any) string {
	b.params = append(b.params, value)
	return fmt.Sprintf("$%d", len(b.params))
}
