#!/usr/bin/env python3

from pathlib import Path
import unittest


CHART_DIR = Path(__file__).resolve().parent
HELPERS = CHART_DIR / "templates" / "_helpers.tpl"
WEB = CHART_DIR / "templates" / "web.yaml"
CORE = CHART_DIR / "templates" / "core.yaml"
GATEWAY = CHART_DIR / "templates" / "agent-gateway.yaml"
VALUES = CHART_DIR / "values.yaml"


class WebNgPublicUrlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helpers = HELPERS.read_text(encoding="utf-8")
        cls.web = WEB.read_text(encoding="utf-8")
        cls.core = CORE.read_text(encoding="utf-8")
        cls.gateway = GATEWAY.read_text(encoding="utf-8")
        cls.values = VALUES.read_text(encoding="utf-8")

    def test_shared_helper_validates_and_canonicalizes_the_origin(self):
        helper_start = self.helpers.index(
            '{{- define "serviceradar.webNgPublicUrl" -}}'
        )
        helper_end = self.helpers.index(
            "\n\n{{/* Fail chart rendering", helper_start
        )
        helper = self.helpers[helper_start:helper_end]

        for contract in (
            "urlParse $publicUrl",
            '(ne $scheme "https")',
            '(and (ne $path "") (ne $path "/"))',
            '(ne $query "")',
            '(ne $fragment "")',
            '(ne $userinfo "")',
            'regexMatch ":[0-9]+$" $host',
            'regexMatch ":443$" $host',
            'trimSuffix "/" $publicUrl',
        ):
            self.assertIn(contract, helper)

        self.assertIn("bare HTTPS origin on port 443", helper)

    def test_every_runtime_consumer_uses_the_shared_canonical_value(self):
        include = '{{- $webNgPublicUrl := include "serviceradar.webNgPublicUrl" . -}}'

        for template in (self.web, self.core, self.gateway):
            self.assertIn(include, template)
            self.assertNotIn(
                '{{- $webNgPublicUrl := default "" $webNg.publicUrl -}}', template
            )

        self.assertIn('{{- $webHost = trimSuffix ":443" $publicUrlHost -}}', self.web)
        self.assertIn(
            '{{- $automationCallbackOrigin := default $webNgPublicUrl '
            "$automationCallbacks.canonicalOrigin -}}",
            self.web,
        )
        self.assertIn("value: {{ $automationCallbackOrigin | quote }}", self.web)
        self.assertIn("value: {{ $webNgPublicUrl | quote }}", self.web)

    def test_values_document_external_origin_and_port_contract(self):
        self.assertIn("publicUrl: \"\"", self.values)
        self.assertIn("trailing root slash is accepted", self.values)
        self.assertIn("explicit ports other than 443 are rejected", self.values)


if __name__ == "__main__":
    unittest.main()
