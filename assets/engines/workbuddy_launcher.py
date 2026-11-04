"""Run the bundled WorkBuddy hub with ZeroApi request-id usage tagging.

This is an external launcher: the vendor source remains untouched. It is
started with the same command-line arguments as wb_proxy.py.
"""

from __future__ import annotations

import functools
import os
from pathlib import Path
import runpy
import sys
import threading


_request_context = threading.local()


def install_request_tracking(namespace):
    """Attach the request's gateway id to every usage row produced in do_POST.

    The vendor's ``_persist_usage(row, fail_label)`` is the common sink for
    both ``record_usage`` and ``record_error``. Keeping the context in
    thread-local storage makes it safe for ThreadingHTTPServer and for
    sequential requests on a keep-alive handler thread.
    """
    handler = namespace["Handler"]
    do_post = handler.do_POST
    # runpy returns a snapshot of the executed globals while function objects
    # retain the live globals dictionary used by record_usage/error.
    module_globals = do_post.__globals__
    persist_usage = module_globals.get("_persist_usage", namespace["_persist_usage"])

    @functools.wraps(persist_usage)
    def persist_with_request_id(row, fail_label):
        request_id = getattr(_request_context, "request_id", None)
        if request_id:
            row["request_id"] = request_id
        return persist_usage(row, fail_label)

    @functools.wraps(do_post)
    def do_post_with_request_id(self, *args, **kwargs):
        previous = getattr(_request_context, "request_id", None)
        raw = self.headers.get("X-ZeroApi-Request-Id")
        request_id = str(raw).strip()[:200] if raw is not None else ""
        _request_context.request_id = request_id or None
        try:
            return do_post(self, *args, **kwargs)
        finally:
            _request_context.request_id = previous

    module_globals["_persist_usage"] = persist_with_request_id
    namespace["_persist_usage"] = persist_with_request_id
    handler.do_POST = do_post_with_request_id


def _hub_path() -> Path:
    configured = os.environ.get("ZEROAPI_WORKBUDDY_HUB")
    if configured:
        return Path(configured).expanduser().resolve()
    # Source checkout: assets/engines/workbuddy_launcher.py -> vendor sibling.
    return Path(__file__).resolve().parents[2] / "vendor" / "workbuddy2api-hub" / "wb_proxy.py"


def main() -> None:
    hub = _hub_path()
    if not hub.is_file():
        raise FileNotFoundError(
            f"WorkBuddy hub not found: {hub}; set ZEROAPI_WORKBUDDY_HUB to wb_proxy.py"
        )

    hub_dir = str(hub.parent)
    if hub_dir not in sys.path:
        sys.path.insert(0, hub_dir)
    # A non-main name skips the vendor's __main__ block. Its public main()
    # accepts no arguments and reads the original sys.argv, matching the
    # existing managed-engine CLI invocation exactly.
    namespace = runpy.run_path(str(hub), run_name="_zeroapi_workbuddy_hub")
    install_request_tracking(namespace)
    namespace["main"]()


if __name__ == "__main__":
    main()
