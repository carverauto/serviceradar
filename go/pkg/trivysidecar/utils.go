package trivysidecar

import "maps"

func cloneMap(input map[string]any) map[string]any {
	if input == nil {
		return map[string]any{}
	}

	output := make(map[string]any, len(input))
	maps.Copy(output, input)
	return output
}
