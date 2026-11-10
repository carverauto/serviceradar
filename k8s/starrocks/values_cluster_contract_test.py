"""Contract tests for k8s/starrocks Helm values profiles."""

import unittest
from pathlib import Path

import yaml


STARROCKS_DIR = Path(__file__).resolve().parent
VALUES_CLUSTER = STARROCKS_DIR / "values-cluster.yaml"
VALUES_CLUSTER_SHARED_DATA = STARROCKS_DIR / "values-cluster-shared-data.yaml"


def anti_affinity_match_labels(values: dict, spec_key: str) -> dict:
    terms = (
        values[spec_key]["affinity"]["podAntiAffinity"][
            "preferredDuringSchedulingIgnoredDuringExecution"
        ]
    )
    return terms[0]["podAffinityTerm"]["labelSelector"]["matchLabels"]


class StarRocksValuesClusterContractTest(unittest.TestCase):
    def test_values_cluster_pod_anti_affinity_uses_operator_component_labels(self):
        values = yaml.safe_load(VALUES_CLUSTER.read_text(encoding="utf-8"))

        self.assertEqual(
            anti_affinity_match_labels(values, "starrocksFESpec"),
            {"app.kubernetes.io/component": "fe"},
        )
        self.assertEqual(
            anti_affinity_match_labels(values, "starrocksBeSpec"),
            {"app.kubernetes.io/component": "be"},
        )

    def test_values_cluster_shared_data_pod_anti_affinity_uses_operator_component_labels(
        self,
    ):
        values = yaml.safe_load(
            VALUES_CLUSTER_SHARED_DATA.read_text(encoding="utf-8")
        )

        self.assertEqual(
            anti_affinity_match_labels(values, "starrocksCnSpec"),
            {"app.kubernetes.io/component": "cn"},
        )


if __name__ == "__main__":
    unittest.main()
