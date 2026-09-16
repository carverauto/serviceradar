package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/go/pkg/terraformprovider"
	"github.com/hashicorp/terraform-plugin-framework/providerserver"
)

var version = "dev"

func main() {
	debug := flag.Bool("debug", false, "enable Terraform provider debugging")
	flag.Parse()
	if err := providerserver.Serve(context.Background(), terraformprovider.New(version), providerserver.ServeOpts{
		Address: "registry.terraform.io/carverauto/serviceradar", Debug: *debug,
	}); err != nil {
		log.Fatal(err)
	}
}
