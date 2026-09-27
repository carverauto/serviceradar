module github.com/carverauto/serviceradar/demo/hello-sim

go 1.25

require (
	github.com/carverauto/serviceradar-sdk-go/v2 v2.1.0
	github.com/carverauto/serviceradar/demo/pluginkit v0.0.0
	github.com/carverauto/serviceradar/demo/simkit v0.0.0
)

require gopkg.in/yaml.v3 v3.0.1 // indirect

// simkit and pluginkit are in this repository; the SDK resolves to its
// released tag through go.sum and the committed vendor/ tree (see
// demo/README.md, Updating the SDK).
replace (
	github.com/carverauto/serviceradar/demo/pluginkit => ../pluginkit
	github.com/carverauto/serviceradar/demo/simkit => ../simkit
)
