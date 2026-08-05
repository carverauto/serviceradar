package slices

func Contains[T comparable](s []T, e T) bool {
	for _, v := range s {
		if v == e {
			return true
		}
	}
	return false
}

func ContainsAll[T comparable](s []T, elements []T) bool {
	for _, element := range elements {
		if !Contains(s, element) {
			return false
		}
	}
	return true
}

func Map[T, R any](f func(T) R, s []T) []R {
	result := make([]R, len(s))
	for i, elem := range s {
		result[i] = f(elem)
	}
	return result
}

func MapCat[T, R any](f func(T) []R, s []T) []R {
	var result []R
	for _, elem := range s {
		result = append(result, f(elem)...)
	}
	return result
}
