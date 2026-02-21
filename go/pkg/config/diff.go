package config

import (
	"reflect"
)

// FieldsChangedByTag returns a list of struct field names whose tag matches any value in triggers
// and whose values differ between old and new. Only compares top-level exported fields.
func FieldsChangedByTag(old, new interface{}, tag string, triggers map[string]bool) []string {
	ov := reflect.Indirect(reflect.ValueOf(old))
	nv := reflect.Indirect(reflect.ValueOf(new))

	if ov.Kind() != reflect.Struct || nv.Kind() != reflect.Struct || ov.Type() != nv.Type() {
		return nil
	}
	t := ov.Type()

	var changed []string

	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)

		if f.PkgPath != "" { // unexported
			continue
		}

		tagVal := f.Tag.Get(tag)
		if tagVal == "" || !triggers[tagVal] {
			continue
		}

		of := ov.Field(i).Interface()
		nf := nv.Field(i).Interface()

		if !reflect.DeepEqual(of, nf) {
			changed = append(changed, f.Name)
		}
	}

	return changed
}
