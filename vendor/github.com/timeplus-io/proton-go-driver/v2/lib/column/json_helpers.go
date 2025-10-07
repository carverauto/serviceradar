package column

import (
	"fmt"
	"sort"
	"strings"
)

func DumpJson(value interface{}) string {
	var builder strings.Builder
	switch v := value.(type) {
	case []string:
		builder.WriteString("[")
		elems_str := make([]string, len(v))
		for i, val := range v {
			elems_str[i] = DumpJson(val)
		}
		builder.WriteString(strings.Join(elems_str, ", "))
		builder.WriteString("]")
	case map[string]interface{}:
		keys := make([]string, 0, len(v))
		for key, _ := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)

		builder.WriteString("{")
		elems_str := make([]string, len(keys))
		for i, key := range keys {
			elems_str[i] = DumpJson(key) + ": " + DumpJson(v[key])
		}
		builder.WriteString(strings.Join(elems_str, ", "))
		builder.WriteString("}")
	case string:
		builder.WriteString("\"")
		builder.WriteString(v)
		builder.WriteString("\"")
	default:
		builder.WriteString(fmt.Sprint(v))
	}

	return builder.String()
}

// For example:
// '{"id": 1, "obj.x": "abc", "obj.y": 2}'
// ->
// '{"id": 1, "obj": { "x": "abc", "y": 2}}'
func NestJson(json map[string]interface{}) map[string]interface{} {
	nested := make(map[string]interface{})
	var curr_path_json map[string]interface{}
	for path, val := range json {
		curr_path_json = nested
		parts := SplitJsonPath(path)
		last_index := len(parts) - 1
		for i, part := range parts {
			if i != last_index {
				if _, ok := curr_path_json[part]; !ok {
					curr_path_json[part] = make(map[string]interface{})
				}
				curr_path_json = curr_path_json[part].(map[string]interface{})
			} else {
				curr_path_json[part] = val
			}
		}
	}
	return nested
}

// Split the json path to sub-paths For example:
// 1) "id" 		-> 	["id"]
// 2) "id.a" 	-> 	["id", "a"]
// 3) "`x.y`.z" ->  ["x.y", "z"]
// ... Others: unknown behavior
func SplitJsonPath(path string) []string {
	var parts []string
	var builder strings.Builder
	has_escape := false
	for _, c := range path {
		switch c {
		case '`':
			has_escape = !has_escape
			builder.WriteRune(c)
		case '.':
			if has_escape {
				builder.WriteRune(c)
			} else {
				parts = append(parts, UnescapeIfForJsonPath(builder.String()))
				builder.Reset()
			}
		default:
			builder.WriteRune(c)
		}
	}

	// last part
	parts = append(parts, UnescapeIfForJsonPath(builder.String()))
	return parts
}

// Split the sub-paths to a whole path For example:
// 1) ["id"] 		-> 	"id"
// 2) ["id", "a"] 	-> 	"id.a"
// 3) ["x.y", "z"] 	-> 	"`x.y`.z"
// ... Others: unknown behavior
func BuildJsonPath(parts []string) string {
	escapeed_parts := make([]string, len(parts))
	for i, part := range parts {
		escapeed_parts[i] = EscapeIfForJsonPath(part)
	}
	return strings.Join(escapeed_parts, ".")
}

// Escaped:
// 1) x.y 		-> 	`x.y`
// 2) `x.y`.a 	-> 	`\`x.y\`.a`
// 3) `x.y``.a	-> 	`\`x.y\`\`.a` (special case)
// No Escape:
// 4) x 		-> 	x
// 5) `x.y` 	-> 	`x.y`
// 6) `x.y`a	-> 	`x.y`a
func EscapeIfForJsonPath(path string) string {
	has_escape := false
	has_dot := false
	for _, c := range path {
		switch c {
		case '`':
			if has_escape {
				has_escape = false
				has_dot = false
			} else {
				has_escape = true
			}
		case '.':
			has_dot = true
			if !has_escape {
				break
			}
		}
	}

	if has_dot {
		var builder strings.Builder
		builder.WriteString("`")
		builder.WriteString(strings.ReplaceAll(path, "`", "\\`"))
		builder.WriteString("`")
		return builder.String()
	} else {
		return path
	}
}

// Unescaped:
// 1) `x.y` 		-> 	x.y
// 2) `\`x.y\`.a`	-> 	`x.y`.a
// No unescape:
// 3) x 		-> 	x
// 4) `x.y`.a	-> 	`x.y`.a
// 5) \`x.y\`.a	-> 	\`x.y\`.a
// 6) `x.y`.a`	-> 	`x.y`.a` (special case)
// 7) ``		-> 	`` (special case)
func UnescapeIfForJsonPath(path string) string {
	if len(path) > 2 && path[0] == '`' && path[len(path)-1] == '`' && strings.Count(path, "`") == strings.Count(path, "\\`")+2 {
		return strings.ReplaceAll(path[1:len(path)-1], "\\`", "`")
	} else {
		return path
	}
}
