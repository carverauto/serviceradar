#!/usr/bin/env python3

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


CHART_DIR = Path(__file__).resolve().parent
HOOK_TEMPLATE = CHART_DIR / "templates" / "flow-collector-strategy-migration-job.yaml"
DEPLOYMENT_TEMPLATE = CHART_DIR / "templates" / "flow-collector.yaml"
DEPLOYMENT_NAME = "serviceradar-flow-collector"
PATCH_BODY = '{"spec":{"strategy":{"$retainKeys":["type"],"type":"Recreate"}}}'
PATCH_CONTENT_TYPE = "Content-Type: application/strategic-merge-patch+json"
PATCH_URL = (
    "https://kubernetes.default.svc/apis/apps/v1/namespaces/"
    f"flow-upgrade-test/deployments/{DEPLOYMENT_NAME}"
)


def template_documents(text: str) -> list[str]:
    return [
        document
        for document in re.split(r"^---\s*$", text, flags=re.MULTILINE)
        if "kind:" in document
    ]


def scalar(document: str, key: str) -> str:
    match = re.search(
        rf"^\s*{re.escape(key)}:\s*[\"']?(?P<value>[^\n\"']+)",
        document,
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError(f"missing {key}")
    return match.group("value").strip()


def extract_migration_script(job_document: str) -> str:
    args_marker = "        - |\n"
    volume_marker = "        volumeMounts:\n"
    args_start = job_document.index(args_marker) + len(args_marker)
    args_end = job_document.index(volume_marker, args_start)
    script_lines = []

    for line in job_document[args_start:args_end].splitlines():
        if line.startswith("          "):
            script_lines.append(line[10:])
        elif not line:
            script_lines.append("")
        else:
            raise AssertionError(f"unexpected script indentation: {line!r}")

    return "\n".join(script_lines) + "\n"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o700)


class FlowCollectorStrategyMigrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hook_text = HOOK_TEMPLATE.read_text(encoding="utf-8")
        cls.deployment_text = DEPLOYMENT_TEMPLATE.read_text(encoding="utf-8")
        cls.hook_documents = template_documents(cls.hook_text)

    def test_hook_lifecycle_and_least_privilege_wiring(self):
        self.assertTrue(
            self.hook_text.startswith("{{- if .Values.flowCollector.enabled }}")
        )
        self.assertTrue(self.hook_text.rstrip().endswith("{{- end }}"))

        self.assertEqual(
            [scalar(document, "kind") for document in self.hook_documents],
            ["ServiceAccount", "Role", "RoleBinding", "Job"],
        )

        for document in self.hook_documents:
            self.assertEqual(scalar(document, "name"), "{{ $name }}")
            self.assertIn('"helm.sh/hook": pre-upgrade', document)
            self.assertIn(
                '"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded',
                document,
            )

        service_account, role, role_binding, job = self.hook_documents
        del service_account

        for document in (role, role_binding):
            self.assertIn('"helm.sh/hook-weight": "-3"', document)
        self.assertIn('"helm.sh/hook-weight": "-3"', self.hook_documents[0])
        self.assertIn('"helm.sh/hook-weight": "-2"', job)

        rules = role[role.index("rules:\n") :].strip()
        self.assertEqual(
            rules,
            textwrap.dedent(
                """\
                rules:
                - apiGroups: ["apps"]
                  resources: ["deployments"]
                  resourceNames: ["serviceradar-flow-collector"]
                  verbs: ["patch"]
                """
            ).strip(),
        )

        self.assertIn(
            "roleRef:\n"
            "  apiGroup: rbac.authorization.k8s.io\n"
            "  kind: Role\n"
            "  name: {{ $name }}",
            role_binding,
        )
        self.assertIn(
            "subjects:\n"
            "- kind: ServiceAccount\n"
            "  name: {{ $name }}\n"
            "  namespace: {{ .Release.Namespace }}",
            role_binding,
        )

        for expected in (
            "serviceAccountName: {{ $name }}",
            "restartPolicy: Never",
            "backoffLimit: 0",
            "activeDeadlineSeconds: 120",
            '{{- include "serviceradar.podSecurityContext" . | nindent 6 }}',
            '{{- include "serviceradar.nonRootContainerSecurityContext" . | nindent 8 }}',
            'command: ["/bin/sh", "-ec"]',
            "volumeMounts:\n        - name: tmp\n          mountPath: /tmp",
            "volumes:\n      - name: tmp\n        emptyDir: {}",
            PATCH_CONTENT_TYPE,
            PATCH_BODY,
        ):
            self.assertIn(expected, job)

        self.assertIn(
            '{{ include "serviceradar.imageRef" '
            '(dict "Values" .Values "Chart" .Chart '
            '"name" "serviceradar-tools" "service" "tools") }}',
            job,
        )

        self.assertRegex(
            self.deployment_text,
            r"(?m)^\s+strategy:\s*\n\s+type:\s+Recreate$",
        )
        self.assertNotIn("rollingUpdate:", self.deployment_text)

    def test_rendered_shell_contract_is_fail_closed(self):
        job = self.hook_documents[3]
        migration_script = extract_migration_script(job)

        self.assertIn("200)", migration_script)
        self.assertIn("404)", migration_script)
        self.assertIn("Failed to migrate Deployment", migration_script)
        self.assertIn(
            ".spec.strategy.type == \"Recreate\" "
            "and (.spec.strategy | has(\"rollingUpdate\") | not)",
            migration_script,
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            fake_bin = temporary / "bin"
            service_account = temporary / "serviceaccount"
            fake_bin.mkdir()
            service_account.mkdir()

            script_path = temporary / "migrate-strategy.sh"
            write_executable(script_path, migration_script)
            self._write_fake_curl(fake_bin / "curl")
            self._write_fake_jq(fake_bin / "jq")

            (service_account / "namespace").write_text(
                "flow-upgrade-test", encoding="utf-8"
            )
            (service_account / "token").write_text(
                "sentinel-service-account-token", encoding="utf-8"
            )
            (service_account / "ca.crt").write_text(
                "fake-ca-for-curl-contract", encoding="utf-8"
            )

            cases = (
                (
                    "patched",
                    True,
                    "200",
                    '{"spec":{"strategy":{"type":"Recreate"}}}',
                    "0",
                ),
                (
                    "absent",
                    True,
                    "404",
                    '{"kind":"Status","message":"not found"}',
                    "0",
                ),
                (
                    "forbidden",
                    False,
                    "403",
                    '{"kind":"Status","message":"forbidden"}',
                    "0",
                ),
                (
                    "stale-response",
                    False,
                    "200",
                    '{"spec":{"strategy":{"type":"Recreate",'
                    '"rollingUpdate":{"maxUnavailable":"25%"}}}}',
                    "0",
                ),
                ("network-error", False, "000", "{}", "7"),
            )

            for name, succeeds, status_code, response, curl_exit in cases:
                with self.subTest(name=name):
                    self._run_case(
                        temporary=temporary,
                        fake_bin=fake_bin,
                        service_account=service_account,
                        script_path=script_path,
                        name=name,
                        succeeds=succeeds,
                        status_code=status_code,
                        response=response,
                        curl_exit=curl_exit,
                    )

    def _run_case(
        self,
        *,
        temporary: Path,
        fake_bin: Path,
        service_account: Path,
        script_path: Path,
        name: str,
        succeeds: bool,
        status_code: str,
        response: str,
        curl_exit: str,
    ) -> None:
        case_dir = temporary / f"case-{name}"
        case_dir.mkdir()
        argv_log = case_dir / "curl-argv.json"
        mode_log = case_dir / "curl-mode.txt"
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                "TMPDIR": str(case_dir),
                "KUBERNETES_SERVICEACCOUNT_DIR": str(service_account),
                "FAKE_EXPECTED_TOKEN": "sentinel-service-account-token",
                "FAKE_CURL_ARGV_LOG": str(argv_log),
                "FAKE_CURL_MODE_LOG": str(mode_log),
                "FAKE_CURL_STATUS": status_code,
                "FAKE_CURL_RESPONSE": response,
                "FAKE_CURL_EXIT": curl_exit,
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(script_path)],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )

        if succeeds:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)

        argv = json.loads(argv_log.read_text(encoding="utf-8"))
        combined_output = json.dumps(argv) + result.stdout + result.stderr
        self.assertNotIn("sentinel-service-account-token", combined_output)
        self.assertEqual(mode_log.read_text(encoding="utf-8"), "600")
        self.assertFalse((case_dir / "curl-auth.conf").exists())
        self.assertFalse((case_dir / "response.json").exists())

        self.assertEqual(self._option_value(argv, "--request"), "PATCH")
        self.assertEqual(self._option_value(argv, "--cacert"), str(service_account / "ca.crt"))
        self.assertEqual(self._option_value(argv, "--header"), "Accept: application/json")
        header_indexes = [index for index, value in enumerate(argv) if value == "--header"]
        self.assertEqual(
            [argv[index + 1] for index in header_indexes],
            ["Accept: application/json", PATCH_CONTENT_TYPE],
        )
        self.assertEqual(self._option_value(argv, "--data"), PATCH_BODY)
        self.assertEqual(argv[-1], PATCH_URL)

    @staticmethod
    def _option_value(arguments: list[str], option: str) -> str:
        index = arguments.index(option)
        return arguments[index + 1]

    @staticmethod
    def _write_fake_curl(path: Path) -> None:
        write_executable(
            path,
            f"""#!{sys.executable}
import json
import os
from pathlib import Path
import stat
import sys

arguments = sys.argv[1:]
Path(os.environ["FAKE_CURL_ARGV_LOG"]).write_text(
    json.dumps(arguments), encoding="utf-8"
)

def option_value(option):
    index = arguments.index(option)
    return arguments[index + 1]

config_path = Path(option_value("--config"))
output_path = Path(option_value("--output"))
expected_config = (
    'header = "Authorization: Bearer '
    + os.environ["FAKE_EXPECTED_TOKEN"]
    + '"\\n'
)
if config_path.read_text(encoding="utf-8") != expected_config:
    raise SystemExit(91)

mode = stat.S_IMODE(config_path.stat().st_mode)
Path(os.environ["FAKE_CURL_MODE_LOG"]).write_text(
    format(mode, "03o"), encoding="utf-8"
)

curl_exit = int(os.environ.get("FAKE_CURL_EXIT", "0"))
if curl_exit:
    raise SystemExit(curl_exit)

output_path.write_text(os.environ["FAKE_CURL_RESPONSE"], encoding="utf-8")
sys.stdout.write(os.environ["FAKE_CURL_STATUS"])
""",
        )

    @staticmethod
    def _write_fake_jq(path: Path) -> None:
        write_executable(
            path,
            f"""#!{sys.executable}
import json
from pathlib import Path
import sys

arguments = sys.argv[1:]
document = json.loads(Path(arguments[-1]).read_text(encoding="utf-8"))

if "-e" in arguments:
    strategy = document.get("spec", {{}}).get("strategy", {{}})
    valid = strategy.get("type") == "Recreate" and "rollingUpdate" not in strategy
    raise SystemExit(0 if valid else 1)

if "-r" in arguments:
    print(document.get("message", "no API error message"))
    raise SystemExit(0)

raise SystemExit(2)
""",
        )


if __name__ == "__main__":
    unittest.main()
