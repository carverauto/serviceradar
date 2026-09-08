import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "ensure_k8s_node_alerts", Path(__file__).parents[1] / "ensure_k8s_node_alerts.py"
)
setup_alerts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup_alerts)


class ProbeRequestTest(unittest.TestCase):
    def test_action_arguments_are_directly_under_data(self):
        client = setup_alerts.JsonApiClient("https://monitor.example.com", "synthetic-token")
        arguments = {"cluster_id": "cluster-example", "node": "node1.example.com", "role": "worker"}
        with patch.object(setup_alerts.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b'{"data": {}}'
            for endpoint in ["k8s-node-not-ready-test", "k8s-node-ready-test"]:
                client.action(f"alerts/{endpoint}", arguments)
                request = urlopen.call_args.args[0]
                self.assertEqual(request.full_url, f"https://monitor.example.com/api/v2/alerts/{endpoint}")
                self.assertEqual(json.loads(request.data), {"data": arguments})

    def test_resource_creation_keeps_resource_envelope(self):
        client = setup_alerts.JsonApiClient("https://monitor.example.com", "synthetic-token")
        with patch.object(setup_alerts.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b'{"data": {}}'
            client.create("notification-routes", "notification_route", {"name": "example"})
            self.assertEqual(json.loads(urlopen.call_args.args[0].data), {
                "data": {"type": "notification_route", "attributes": {"name": "example"}}
            })


if __name__ == "__main__":
    unittest.main()
