"""Unit tests for the TLC result judge. Fixture lines are copied from a real TLC 1.7.4 run
on the synthetic Counter spec; they contain no data from any deployment."""

import unittest

import tlc_driver

PASS_OUT = (
    "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)\n"
    "Model checking completed. No error has been found.\n"
)
INV_OUT = (
    "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)\n"
    "Error: Invariant Bounded is violated.\n"
    "Error: The behavior up to this point is:\n"
)
ACT_OUT = (
    "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)\n"
    "Error: Action property NeverSkips is violated.\n"
    "Error: The behavior up to this point is:\n"
)
CONFIG_ERROR_OUT = (
    "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)\n"
    "Error: The invariant Nope specified in the configuration file\n"
    "is not defined in the specification.\n"
)


class ParseExpectTest(unittest.TestCase):
    def test_parse_expect_pass(self):
        self.assertEqual(tlc_driver.parse_expect("pass"), ("pass", None))

    def test_parse_expect_violation(self):
        self.assertEqual(
            tlc_driver.parse_expect("violation:NoZombieRevival"),
            ("violation", "NoZombieRevival"),
        )

    def test_parse_expect_rejects_malformed(self):
        for bad in ["", "fail", "violation:", "Violation:X", "violation:has space", "pass:X"]:
            with self.subTest(expect=bad):
                with self.assertRaises(ValueError):
                    tlc_driver.parse_expect(bad)


class JudgeTest(unittest.TestCase):
    def test_pass_expected_and_found(self):
        ok, _ = tlc_driver.judge(0, PASS_OUT, "pass")
        self.assertTrue(ok)

    def test_exit_zero_without_success_line_fails(self):
        ok, reason = tlc_driver.judge(0, "TLC2 Version 2.19\n", "pass")
        self.assertFalse(ok)
        self.assertIn("success line", reason)

    def test_pass_expected_but_violation_found(self):
        ok, reason = tlc_driver.judge(12, INV_OUT, "pass")
        self.assertFalse(ok)
        self.assertIn("Bounded", reason)

    def test_invariant_violation_expected_and_found(self):
        ok, _ = tlc_driver.judge(12, INV_OUT, "violation:Bounded")
        self.assertTrue(ok)

    def test_action_property_violation_expected_and_found(self):
        ok, _ = tlc_driver.judge(13, ACT_OUT, "violation:NeverSkips")
        self.assertTrue(ok)

    def test_wrong_property_fails(self):
        ok, reason = tlc_driver.judge(12, INV_OUT, "violation:NeverSkips")
        self.assertFalse(ok)
        self.assertIn("Bounded", reason)
        self.assertIn("NeverSkips", reason)

    def test_violation_expected_but_passed(self):
        ok, reason = tlc_driver.judge(0, PASS_OUT, "violation:Bounded")
        self.assertFalse(ok)
        self.assertIn("no violation", reason)

    def test_config_error_fails_every_expectation(self):
        for expect in ["pass", "violation:Nope", "violation:Bounded"]:
            with self.subTest(expect=expect):
                ok, reason = tlc_driver.judge(151, CONFIG_ERROR_OUT, expect)
                self.assertFalse(ok)
                self.assertIn("151", reason)

    def test_violation_line_with_mismatched_exit_code_fails(self):
        ok, _ = tlc_driver.judge(1, INV_OUT, "violation:Bounded")
        self.assertFalse(ok)

    def test_two_violation_lines_fail(self):
        ok, reason = tlc_driver.judge(12, INV_OUT + "Error: Invariant Other is violated.\n", "violation:Bounded")
        self.assertFalse(ok)
        self.assertIn("Other", reason)


if __name__ == "__main__":
    unittest.main()
