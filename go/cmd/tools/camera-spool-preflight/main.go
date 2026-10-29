// camera-spool-preflight observes a retained volume association without granting
// initialization, recording or controller-conversion authority.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const requestTimeout = 30 * time.Second

type options struct {
	kubeconfig, kubeContext string
	namespace, namespaceUID string
	claim, claimUID         string
	volume, volumeUID       string
	driver, handle          string
	minimumBytes            int64
}

type result struct {
	Status string `json:"status"`
	Reason string `json:"reason,omitempty"`
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout))
}

func run(args []string, output io.Writer) int {
	o, help, valid := parseOptions(args)
	if help {
		_, err := fmt.Fprintln(output, "camera-spool-preflight requires --kubeconfig, --context, --namespace, --namespace-uid, --claim, --claim-uid, --volume, --volume-uid, --csi-driver, --csi-handle, --minimum-bytes. Supply expected identities from retained inventory. Success is a read-only API observation, not storage qualification or permission to initialize.")
		if err != nil {
			return 1
		}
		return 0
	}
	if !valid {
		return emit(output, "invalid_input")
	}

	config, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: o.kubeconfig},
		&clientcmd.ConfigOverrides{CurrentContext: o.kubeContext},
	).ClientConfig()
	if err != nil {
		return emit(output, "kubeconfig_invalid")
	}
	config.Timeout = requestTimeout
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return emit(output, "kubernetes_client_invalid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	return emit(output, inspect(ctx, client, o))
}

func emit(output io.Writer, reason string) int {
	r := result{Status: "association_verified"}
	code := 0
	if reason != "" {
		r = result{Status: "refused", Reason: reason}
		code = 1
	}
	if err := json.NewEncoder(output).Encode(r); err != nil {
		return 1
	}
	return code
}

func parseOptions(args []string) (options, bool, bool) {
	var o options
	f := flag.NewFlagSet("camera-spool-preflight", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&o.kubeconfig, "kubeconfig", "", "explicit operator kubeconfig")
	f.StringVar(&o.kubeContext, "context", "", "explicit kubeconfig context")
	f.StringVar(&o.namespace, "namespace", "", "expected namespace name")
	f.StringVar(&o.namespaceUID, "namespace-uid", "", "retained namespace UID")
	f.StringVar(&o.claim, "claim", "", "expected PVC name")
	f.StringVar(&o.claimUID, "claim-uid", "", "retained PVC UID")
	f.StringVar(&o.volume, "volume", "", "expected PV name")
	f.StringVar(&o.volumeUID, "volume-uid", "", "retained PV UID")
	f.StringVar(&o.driver, "csi-driver", "", "retained CSI driver name")
	f.StringVar(&o.handle, "csi-handle", "", "retained CSI volume handle")
	f.Int64Var(&o.minimumBytes, "minimum-bytes", 0, "retained minimum capacity")
	if err := f.Parse(args); err != nil {
		return o, errors.Is(err, flag.ErrHelp), false
	}
	valid := f.NArg() == 0 && o.kubeconfig != "" && o.kubeContext != "" && o.minimumBytes > 0 &&
		o.namespace != "" && len(validation.IsDNS1123Label(o.namespace)) == 0 &&
		o.claim != "" && len(validation.IsDNS1123Subdomain(o.claim)) == 0 &&
		o.volume != "" && len(validation.IsDNS1123Subdomain(o.volume)) == 0 &&
		o.driver != "" && len(validation.IsDNS1123Subdomain(o.driver)) == 0
	for _, uid := range []string{o.namespaceUID, o.claimUID, o.volumeUID} {
		valid = valid && len(uid) > 0 && len(uid) <= 128
	}
	valid = valid && len(o.handle) > 0 && len(o.handle) <= 1024
	return o, false, valid
}
