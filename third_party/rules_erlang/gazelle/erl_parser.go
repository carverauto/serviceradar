package erlang

type ErlAttrs struct {
	IncludeLib     []string            `json:"include_lib"`
	Include        []string            `json:"include"`
	Behaviour      []string            `json:"behaviour"`
	ParseTransform []string            `json:"parse_transform"`
	Call           map[string][]string `json:"call"`
}

func (attrs *ErlAttrs) modules() []string {
	return append(attrs.Behaviour, attrs.ParseTransform...)
}

type ErlParserMacros map[string]*string

type ErlParserIncludePaths []string

type ErlParser interface {
	DeepParseErl(string, *ErlangApp, ErlParserMacros, ErlParserIncludePaths) (*ErlAttrs, error)
}
