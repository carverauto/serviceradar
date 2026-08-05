package mutable_set_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/rabbitmq/rules_erlang/gazelle/mutable_set"
	"strings"
	"testing"
)

func TestUpdate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "MutableSet Suite")
}

var _ = Describe("MutableSet", func() {
	Describe("Contains", func() {
		It("creates a set", func() {
			s := mutable_set.New("a")
			Expect(s.Contains("a")).To(BeTrue())
			Expect(s.Contains("b")).To(BeFalse())
		})
	})

	Describe("Map", func() {
		It("transforms the set's values", func() {
			in := mutable_set.New("first", "second", "third")
			out := mutable_set.Map(in, strings.ToUpper)

			Expect(out.ValuesUnordered()).To(ContainElements(
				"FIRST",
				"SECOND",
				"THIRD",
			))
		})
	})
})
