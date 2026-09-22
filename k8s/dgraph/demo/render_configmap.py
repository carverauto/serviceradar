#!/usr/bin/env python3
"""Wrap dashboard.json into dashboard-configmap.yaml.

Grafana's kiwigrid sidecar watches every namespace for ConfigMaps labelled
grafana_dashboard=1, so the dashboard ships next to Dgraph rather than in the
monitoring namespace, and deploy-dgraph.sh can apply it with everything else.

    python3 k8s/dgraph/demo/gen_dashboard.py
    python3 k8s/dgraph/demo/render_configmap.py
"""
from pathlib import Path

here = Path(__file__).resolve().parent
body = (here / "dashboard.json").read_text().rstrip("\n")
indented = "\n".join("    " + line for line in body.splitlines())
(here / "dashboard-configmap.yaml").write_text(f"""# Grafana picks this up from any namespace: the kiwigrid sidecar watches for
# ConfigMaps labelled grafana_dashboard=1 cluster-wide, so the dashboard ships
# next to Dgraph instead of in the monitoring namespace.
#
# Generated -- do not hand-edit. Change gen_dashboard.py and re-run:
#   python3 k8s/dgraph/demo/gen_dashboard.py
#   python3 k8s/dgraph/demo/render_configmap.py
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-dgraph
  namespace: demo
  labels:
    grafana_dashboard: "1"
    app: dgraph
    app.kubernetes.io/managed-by: serviceradar
  annotations:
    grafana_folder: Dgraph
    k8s-sidecar-target-directory: /tmp/dashboards/Dgraph
data:
  dgraph.json: |
{indented}
""")
print("wrote dashboard-configmap.yaml")
