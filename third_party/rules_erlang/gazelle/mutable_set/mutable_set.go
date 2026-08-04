package mutable_set

import (
	"sort"
)

type MutableSet[T comparable] map[T]bool

func New[T comparable](items ...T) MutableSet[T] {
	s := make(MutableSet[T])
	s.Add(items...)
	return s
}

func (s MutableSet[T]) IsEmpty() bool {
	return len(s) == 0
}

func (s MutableSet[T]) Contains(item T) bool {
	return s[item]
}

func (s MutableSet[T]) Add(items ...T) {
	for _, item := range items {
		s[item] = true
	}
}

func (s MutableSet[T]) Union(other MutableSet[T]) {
	for item, present := range other {
		if present {
			s[item] = true
		}
	}
}

func (s MutableSet[T]) Any() T {
	var result T
	for item, present := range s {
		if present {
			result = item
			break
		}
	}
	return result
}

func (s MutableSet[T]) ForEach(f func(v T)) {
	for item, present := range s {
		if present {
			f(item)
		}
	}
}

func (s MutableSet[T]) Subtract(other MutableSet[T]) {
	for item, present := range other {
		if present {
			delete(s, item)
		}
	}
}

func (s MutableSet[T]) Clone() MutableSet[T] {
	r := make(MutableSet[T], len(s))
	for item, present := range s {
		if present {
			r[item] = true
		}
	}
	return r
}

func (s MutableSet[T]) Filter(pred func(v T) bool) MutableSet[T] {
	r := make(MutableSet[T])
	for item, present := range s {
		if present && pred(item) {
			r[item] = true
		}
	}
	return r
}

func GroupBy[T, K comparable](s MutableSet[T], f func(v T) K) map[K][]T {
	r := make(map[K][]T, len(s))
	s.ForEach(func(v T) {
		k := f(v)
		r[k] = append(r[k], v)
	})
	return r
}

func Index[T, K comparable](s MutableSet[T], f func(v T) K) map[K]T {
	r := make(map[K]T, len(s))
	s.ForEach(func(v T) {
		r[f(v)] = v
	})
	return r
}

func Map[T, R comparable](s MutableSet[T], f func(v T) R) MutableSet[R] {
	r := make(MutableSet[R], len(s))
	for item, present := range s {
		if present {
			r[f(item)] = true
		}
	}
	return r
}

func Union[T comparable](sets ...MutableSet[T]) MutableSet[T] {
	result := New[T]()
	for _, set := range sets {
		for item := range set {
			result.Add(item)
		}
	}
	return result
}

func Copy[T comparable](set MutableSet[T]) MutableSet[T] {
	return Union(set, New[T]())
}

func (s MutableSet[T]) Values(compare func(i T, j T) int) []T {
	values := s.ValuesUnordered()
	sort.SliceStable(values, func(i, j int) bool {
		return compare(values[i], values[j]) == -1
	})
	return values
}

func (s MutableSet[T]) ValuesUnordered() []T {
	var values []T
	for item := range s {
		values = append(values, item)
	}
	return values
}
