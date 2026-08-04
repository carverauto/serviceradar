package erlang_test

import (
	"fmt"

	"github.com/onsi/gomega/types"
	"github.com/rabbitmq/rules_erlang/gazelle/mutable_set"
)

// we need go 1.20 in order to drop the type parameter and cast
// to MutableSet[any] inside the match method
// https://go.dev/blog/comparable

type MutableSetContainsMatcher[T comparable] struct {
	expected types.GomegaMatcher
}

func MutableSetContains[T comparable](expected types.GomegaMatcher) types.GomegaMatcher {
	return &MutableSetContainsMatcher[T]{expected: expected}
}

func (m *MutableSetContainsMatcher[T]) Match(actual interface{}) (bool, error) {
	if f, ok := actual.(mutable_set.MutableSet[T]); ok {
		for item, ok := range f {
			if ok {
				matched, _ := m.expected.Match(item)
				if matched {
					return true, nil
				}
			}
		}
	} else if f, ok := actual.(*mutable_set.MutableSet[T]); ok {
		for item, ok := range *f {
			if ok {
				matched, _ := m.expected.Match(item)
				if matched {
					return true, nil
				}
			}
		}
	} else {
		return false, fmt.Errorf("MutableSetContains matcher expects a mutable_set.MutableSet")
	}
	return false, nil
}

func (m *MutableSetContainsMatcher[T]) FailureMessage(actual interface{}) string {
	return fmt.Sprintf("Expected\n\t%#v\nto contain an element matching\n\t%#v", actual, m.expected)
}

func (m *MutableSetContainsMatcher[T]) NegatedFailureMessage(actual interface{}) string {
	return fmt.Sprintf("Expected\n\t%#v\nnot to contain an element matching\n\t%#v", actual, m.expected)
}
