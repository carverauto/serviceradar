package cli

import (
	"context"
	"fmt"
	"sort"

	clihydrate "github.com/carverauto/serviceradar/pkg/cli/hydrate"
)

// RunHydrate executes the hydrate subcommand.
func RunHydrate(cfg *CmdConfig) error {
	opts := clihydrate.Options{
		BundlePath: cfg.HydrateBundlePath,
		Services:   cfg.HydrateServices,
		Force:      cfg.HydrateForce,
		Timeout:    cfg.HydrateTimeout,
	}

	summary, err := clihydrate.Execute(context.Background(), opts)
	if err != nil {
		return err
	}

	fmt.Printf("Hydration source: %s\n", summary.Source)
	if len(summary.Results) == 0 {
		fmt.Println("No matching configuration entries.")
		return nil
	}

	// Ensure stable output order (Execute already sorts, but double-sort in case of modifications).
	sort.Slice(summary.Results, func(i, j int) bool {
		if summary.Results[i].Component == summary.Results[j].Component {
			return summary.Results[i].KVKey < summary.Results[j].KVKey
		}

		return summary.Results[i].Component < summary.Results[j].Component
	})

	fmt.Printf("%-18s %-36s %s\n", "Component", "KV Key", "Action")
	for _, res := range summary.Results {
		fmt.Printf("%-18s %-36s %s\n", res.Component, res.KVKey, res.Action)
	}

	created := 0
	overwritten := 0
	skipped := 0
	for _, res := range summary.Results {
		switch res.Action {
		case clihydrate.ActionCreated:
			created++
		case clihydrate.ActionOverwritten:
			overwritten++
		case clihydrate.ActionSkipped:
			skipped++
		}
	}

	fmt.Printf("\nSummary: %d created, %d overwritten, %d skipped\n", created, overwritten, skipped)

	return nil
}
