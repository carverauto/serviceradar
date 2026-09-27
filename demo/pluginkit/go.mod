module github.com/carverauto/serviceradar/demo/pluginkit

go 1.25

require (
	github.com/carverauto/serviceradar-sdk-go/v2 v2.1.0
	github.com/carverauto/serviceradar/demo/simkit v0.0.0
)

replace (
	github.com/carverauto/serviceradar-sdk-go/v2 => ../third_party/serviceradar-sdk-go
	github.com/carverauto/serviceradar/demo/simkit => ../simkit
)
