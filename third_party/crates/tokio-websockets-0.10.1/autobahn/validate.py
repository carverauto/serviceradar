import json
import os

AUTOBAHN_DIR = os.path.dirname(__file__)
CLIENTS = os.sep.join([AUTOBAHN_DIR, "reports", "clients", "index.json"])
SERVERS = os.sep.join([AUTOBAHN_DIR, "reports", "servers", "index.json"])

def validate_report_json(json):
    for (client, cases) in json.items():
        if "tokio-websockets" not in client:
            continue # We do not care about other libraries' results

        allowed_behavior = ("OK", "INFORMATIONAL", "UNIMPLEMENTED")

        for (report, result) in cases.items():
            behavior = result["behavior"]
            behavior_close = result["behaviorClose"]

            if behavior not in allowed_behavior or behavior_close not in allowed_behavior:
                raise Exception(f"Case {report} failed: {result}")

def load_reports(path):
    with open(path, "r") as f:
        return json.load(f)

validate_report_json(load_reports(CLIENTS))
validate_report_json(load_reports(SERVERS))
