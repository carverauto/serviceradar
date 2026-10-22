package mtr

import (
	"errors"
	"math"
	"testing"
)

func TestUint16FromIntRejectsValuesOutsideTheWireWidth(t *testing.T) {
	t.Parallel()

	got, err := uint16FromInt(math.MaxUint16)
	if err != nil || got != math.MaxUint16 {
		t.Fatalf("max uint16: got %d err %v", got, err)
	}

	if _, err := uint16FromInt(math.MaxUint16 + 1); !errors.Is(err, errIntegerWidth) {
		t.Fatalf("one past max uint16: %v", err)
	}

	if _, err := uint16FromInt(-1); !errors.Is(err, errIntegerWidth) {
		t.Fatalf("negative: %v", err)
	}
}

func TestInt32FromIntRejectsValuesOutsideTheDescriptorWidth(t *testing.T) {
	t.Parallel()

	got, err := int32FromInt(math.MaxInt32)
	if err != nil || got != math.MaxInt32 {
		t.Fatalf("max int32: got %d err %v", got, err)
	}

	if _, err := int32FromInt(math.MaxInt32 + 1); !errors.Is(err, errIntegerWidth) {
		t.Fatalf("one past max int32: %v", err)
	}

	if _, err := int32FromInt(math.MinInt32 - 1); !errors.Is(err, errIntegerWidth) {
		t.Fatalf("one below min int32: %v", err)
	}
}
