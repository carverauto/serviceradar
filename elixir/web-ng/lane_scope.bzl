"""Scope target for the web-ng lane-routing query.

The routing contract has to see every ex_unit_test in this package, including a
manual target that lands above the call site by merge. native.existing_rules()
only sees rules already defined, so web-ng's BUILD calls this last.
"""

def web_ng_lane_scope(name):
    tests = []
    kinds = {}
    for rule_name, rule in native.existing_rules().items():
        kind = rule.get("kind", "")
        kinds[kind] = kinds.get(kind, 0) + 1
        if kind == "ex_unit_test" or kind.endswith(":ex_unit_test"):
            tests.append(":" + rule_name)
    if not tests:
        fail("web-ng lane scope found no ex_unit_test rules; kinds: %s" % kinds)
    native.test_suite(
        name = name,
        tags = ["manual"],
        tests = sorted(tests),
    )
