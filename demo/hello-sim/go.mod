module github.com/carverauto/serviceradar/demo/hello-sim

go 1.25

require (
	github.com/carverauto/serviceradar-sdk-go/v2 v2.1.0
	github.com/carverauto/serviceradar/demo/pluginkit v0.0.0
	github.com/carverauto/serviceradar/demo/simkit v0.0.0
)

// Every dependency is a directory in this repository, so the TinyGo build
// resolves offline from declared Bazel inputs (no vendor tree, no proxy).
replace (
	github.com/carverauto/serviceradar-sdk-go/v2 => ../third_party/serviceradar-sdk-go
	github.com/carverauto/serviceradar/demo/pluginkit => ../pluginkit
	github.com/carverauto/serviceradar/demo/simkit => ../simkit
)
