"""Concurrency and keep-alive tests for the external WorkBuddy launcher."""

import importlib.util
import json
from pathlib import Path
import threading
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "assets" / "engines" / "workbuddy_launcher.py"
spec = importlib.util.spec_from_file_location("workbuddy_launcher", LAUNCHER)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class Headers(dict):
    def get(self, key, default=None):
        return super().get(key.lower(), default)


class Handler:
    def __init__(self, request_id):
        self.headers = Headers({"x-zeroapi-request-id": request_id} if request_id else {})

    def do_POST(self):
        # Model the vendor's success and failure usage paths. Both land in the
        # common persistence sink while this request's context is active.
        self.namespace["_persist_usage"]({"outcome": "completed"}, "usage")
        self.namespace["_persist_usage"]({"error": True}, "error")


_BASE_DO_POST = Handler.do_POST


class WorkBuddyRequestIdTests(unittest.TestCase):
    def setUp(self):
        self.rows = []
        Handler.do_POST = _BASE_DO_POST
        self.namespace = {
            "Handler": Handler,
            "_persist_usage": lambda row, label: self.rows.append(dict(row)),
        }
        globals()["_persist_usage"] = self.namespace["_persist_usage"]
        Handler.namespace = self.namespace
        launcher.install_request_tracking(self.namespace)

    def test_keep_alive_replaces_then_clears_id(self):
        handler = Handler("req-one")
        handler.do_POST()
        handler.headers = Headers({"x-zeroapi-request-id": "req-two"})
        handler.do_POST()
        handler.headers = Headers()
        handler.do_POST()

        self.assertEqual([r.get("request_id") for r in self.rows], [
            "req-one", "req-one", "req-two", "req-two", None, None,
        ])

    def test_concurrent_handler_threads_do_not_cross_ids(self):
        barrier = threading.Barrier(8)

        def run(index):
            barrier.wait()
            Handler(f"id-{index}").do_POST()

        threads = [threading.Thread(target=run, args=(i,)) for i in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())

        rows = json.loads(json.dumps(self.rows))
        by_id = {}
        for row in rows:
            by_id.setdefault(row["request_id"], []).append(row)
        self.assertEqual(set(by_id), {f"id-{i}" for i in range(8)})
        self.assertTrue(all(len(pair) == 2 for pair in by_id.values()))
        self.assertTrue(all(pair[0]["outcome"] == "completed" for pair in by_id.values()))
        self.assertTrue(all(pair[1]["error"] for pair in by_id.values()))

    def test_no_gateway_header_means_no_request_id(self):
        Handler(None).do_POST()
        self.assertTrue(all("request_id" not in row for row in self.rows))


if __name__ == "__main__":
    unittest.main()
