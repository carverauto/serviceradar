#!/usr/bin/env python3
"""CNPG credential templates must not mint a new password when lookup is empty.

Argo CD renders Helm on repo-server, which cannot GET namespace Secrets.
lookup therefore returns empty on every sync. A randAlphaNum fallback in
that path rotated serviceradar-db-credentials / cnpg-superuser and rolled
core and web-ng (checksum/db-credentials) on each apply.

The intended behaviour is still in values.yaml: reuse existing secrets;
delete/recreate to rotate. First-install create-if-missing belongs in the
secret-generator job, which can talk to the API and treats HTTP 409 as
"leave the password alone".
"""

import os
import re
import unittest

# Helm function calls, not the identifier in a comment.
RANDOMIZE = re.compile(r"randAlphaNum\s+\d+|randAlphaNum\s*\|")

HERE = os.path.dirname(os.path.abspath(__file__))


def read(rel):
    with open(os.path.join(HERE, rel), "r", encoding="utf-8") as handle:
        return handle.read()


class CnpgCredentialsLookupTest(unittest.TestCase):
    def test_helpers_do_not_mint_random_passwords_or_checksums(self):
        helpers = read("templates/_helpers.tpl")
        self.assertIn("serviceradar.dbCredentialsChecksum", helpers)
        self.assertIn("serviceradar.reuseSecretPassword", helpers)
        self.assertIn("lookup-unavailable", helpers)
        self.assertIsNone(
            RANDOMIZE.search(helpers),
            "_helpers.tpl must not call randAlphaNum (Argo lookup is empty every sync)",
        )

    def test_cluster_templates_do_not_mint_random_passwords(self):
        for rel in (
            "templates/cnpg-cluster.yaml",
            "templates/spire-postgres.yaml",
        ):
            text = read(rel)
            self.assertIsNone(
                RANDOMIZE.search(text),
                "%s must not call randAlphaNum (Argo lookup is empty every sync)" % rel,
            )
            self.assertIn("serviceradar.reuseSecretPassword", text)
            self.assertIn("argocd.argoproj.io/sync-options", text)
            self.assertIn("Prune=false", text)

    def test_secret_generator_creates_cnpg_secrets_only_when_missing(self):
        job = read("templates/secret-generator-job.yaml")
        self.assertIn("ensure_cnpg_secret", job)
        self.assertIn("CNPG_APP_SECRET_NAME", job)
        self.assertIn("CNPG_SUPERUSER_SECRET_NAME", job)
        self.assertIn("leaving password unchanged", job)
        self.assertIn("409", job)
        self.assertIn("application/merge-patch+json", job)
        self.assertIn(
            '{"metadata":{"annotations":{"helm.sh/resource-policy":"keep","argocd.argoproj.io/sync-options":"Prune=false"}}}',
            job,
        )

    def test_values_still_forbid_upgrade_rotation(self):
        values = read("values.yaml")
        self.assertIn("does not mint a random password when lookup is empty", values)
        self.assertIn("HTTP 409 leaves the password unchanged", values)


if __name__ == "__main__":
    unittest.main()
