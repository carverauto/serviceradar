package main

import (
	"strconv"
	"strings"
)

func rawItemsArray(raw string) string {
	start, end, ok := jsonValueSpan(raw, "items")
	if !ok || start >= end || raw[start] != '[' {
		return ""
	}

	return raw[start:end]
}

func rawJSONObjectList(raw string) []string {
	out := []string{}
	start := -1
	depth := 0
	inString := false
	escaped := false

	for i := range raw {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
			}
			continue
		}

		switch ch {
		case '"':
			inString = true
		case '{':
			if depth == 0 {
				start = i
			}
			depth++
		case '}':
			if depth == 0 {
				continue
			}
			depth--
			if depth == 0 && start >= 0 {
				out = append(out, raw[start:i+1])
				start = -1
			}
		}
	}

	return out
}

func jsonStringValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return ""
	}
	value := strings.TrimSpace(raw[start:end])
	if value == "" || value == "null" {
		return ""
	}
	if strings.HasPrefix(value, `"`) {
		unquoted, err := strconv.Unquote(value)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(unquoted)
	}

	return strings.Trim(value, ` "`)
}

func jsonIntValue(raw string, key string) int {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return 0
	}
	value := strings.TrimSpace(raw[start:end])
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0
	}

	return parsed
}

func jsonFloatValue(raw string, key string) float64 {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return 0
	}
	value := strings.TrimSpace(raw[start:end])
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0
	}

	return parsed
}

func jsonStringArrayValue(raw string, key string) []string {
	array := jsonArrayValue(raw, key)
	if array == "" {
		return nil
	}
	values := make([]string, 0)
	for i := 1; i < len(array)-1; {
		i = skipJSONWhitespace(array, i)
		if i >= len(array)-1 || array[i] == ']' {
			break
		}
		if array[i] == '"' {
			end := jsonStringEnd(array, i)
			if end < 0 {
				break
			}
			if value, err := strconv.Unquote(array[i : end+1]); err == nil {
				values = append(values, value)
			}
			i = end + 1
		} else {
			end := jsonValueEnd(array, i)
			if end < 0 {
				break
			}
			value := strings.TrimSpace(array[i:end])
			if value != "" && value != "null" {
				values = append(values, strings.Trim(value, ` "`))
			}
			i = end
		}
		for i < len(array) && array[i] != ',' && array[i] != ']' {
			i++
		}
		if i < len(array) && array[i] == ',' {
			i++
		}
	}
	if len(values) == 0 {
		return nil
	}

	return values
}

func jsonBoolValue(raw string, key string) (bool, bool) {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return false, false
	}
	switch strings.TrimSpace(raw[start:end]) {
	case "true":
		return true, true
	case "false":
		return false, true
	default:
		return false, false
	}
}

func jsonValueSpan(raw string, key string) (int, int, bool) {
	colon, ok := jsonKeyColon(raw, key)
	if !ok {
		return 0, 0, false
	}
	start := skipJSONWhitespace(raw, colon+1)
	if start >= len(raw) {
		return 0, 0, false
	}

	switch raw[start] {
	case '"':
		end := jsonStringEnd(raw, start)
		if end < 0 {
			return 0, 0, false
		}
		return start, end + 1, true
	case '{', '[':
		end := jsonCompositeEnd(raw, start)
		if end < 0 {
			return 0, 0, false
		}
		return start, end + 1, true
	default:
		end := start
		for end < len(raw) && raw[end] != ',' && raw[end] != '}' && raw[end] != ']' {
			end++
		}
		return start, end, true
	}
}

func jsonKeyColon(raw string, key string) (int, bool) {
	inString := false
	escaped := false
	stringStart := -1

	for i := range raw {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
				if stringStart >= 0 {
					quoted := raw[stringStart : i+1]
					unquoted, err := strconv.Unquote(quoted)
					if err == nil && unquoted == key {
						next := skipJSONWhitespace(raw, i+1)
						if next < len(raw) && raw[next] == ':' {
							return next, true
						}
					}
				}
			}
			continue
		}
		if ch == '"' {
			inString = true
			stringStart = i
		}
	}

	return 0, false
}

func jsonStringEnd(raw string, start int) int {
	escaped := false
	for i := start + 1; i < len(raw); i++ {
		if escaped {
			escaped = false
			continue
		}
		switch raw[i] {
		case '\\':
			escaped = true
		case '"':
			return i
		}
	}

	return -1
}

func jsonValueEnd(raw string, start int) int {
	if start >= len(raw) {
		return -1
	}
	switch raw[start] {
	case '"':
		end := jsonStringEnd(raw, start)
		if end < 0 {
			return -1
		}
		return end + 1
	case '{', '[':
		end := jsonCompositeEnd(raw, start)
		if end < 0 {
			return -1
		}
		return end + 1
	default:
		end := start
		for end < len(raw) && raw[end] != ',' && raw[end] != '}' && raw[end] != ']' {
			end++
		}
		return end
	}
}

func jsonCompositeEnd(raw string, start int) int {
	open := raw[start]
	close := byte('}')
	if open == '[' {
		close = ']'
	}

	depth := 0
	inString := false
	escaped := false

	for i := start; i < len(raw); i++ {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
			}
			continue
		}

		switch ch {
		case '"':
			inString = true
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i
			}
		}
	}

	return -1
}

func skipJSONWhitespace(raw string, start int) int {
	for start < len(raw) {
		switch raw[start] {
		case ' ', '\n', '\r', '\t':
			start++
		default:
			return start
		}
	}

	return start
}
