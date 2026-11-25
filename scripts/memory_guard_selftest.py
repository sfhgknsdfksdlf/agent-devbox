#!/usr/bin/env python3
"""Build-time integration test for memory_guard's allowlist boundary.

Run with the mcp-memory-service tool venv (fastapi + httpx installed), for
example from the core image:

    /opt/uv-tools/mcp-memory-service/bin/python /usr/local/bin/memory_guard_selftest.py

The upstream app is a real FastAPI app that registers its routes through
``include_router()``. FastAPI 0.165 represents such routers as
``fastapi.routing._IncludedRouter`` objects with no ``path``/``methods``, which
is exactly the shape that must NOT be stripped: the allowlist middleware keeps
``/api/health`` reachable and 404s every non-allowlisted request before routing.
"""

from __future__ import annotations

from fastapi import APIRouter, FastAPI
from fastapi.testclient import TestClient

import memory_guard


def build_upstream() -> FastAPI:
    """A real FastAPI app whose API routers use include_router()."""
    app = FastAPI()

    @app.get("/")
    def dashboard():
        return {"dashboard": True}

    @app.get("/static/app.js")
    def static_asset():
        return {"should": "be blocked"}

    api = APIRouter()

    @api.get("/health")
    def health():
        return {"status": "healthy"}

    @api.get("/health/detailed")
    def health_detailed():
        return {"status": "healthy", "detailed": True}

    @api.post("/memories")
    def memories():
        return {"ok": True}

    @api.get("/memories")
    def memories_get():
        return {"should": "be blocked"}

    @api.delete("/memories/{content_hash}")
    def memories_delete(content_hash: str):
        return {"deleted": content_hash}

    @api.post("/config/credentials")
    def credentials():
        raise AssertionError("credential route must never run")

    app.include_router(api, prefix="/api")
    return app


def main() -> int:
    client = TestClient(memory_guard.build_app(build_upstream()))

    allowed = (
        ("GET", "/api/health", 200),
        ("GET", "/api/health/detailed", 200),
        ("POST", "/api/memories", 200),
        ("DELETE", "/api/memories/" + "a" * 64, 200),
    )
    for method, path, expected in allowed:
        response = client.request(method, path)
        if response.status_code != expected:
            raise SystemExit(
                f"FAIL: {method} {path}: expected {expected}, got {response.status_code}"
            )

    denied = (
        ("GET", "/"),
        ("GET", "/openapi.json"),
        ("GET", "/api/docs"),
        ("GET", "/static/app.js"),
        ("POST", "/api/config/credentials"),
        ("POST", "/api/health"),
        ("GET", "/api/memories"),
        ("GET", "/api/health/../config/env"),
        ("GET", "//api/health"),
    )
    for method, path in denied:
        response = client.request(method, path)
        if response.status_code != 404:
            raise SystemExit(
                f"FAIL: {method} {path}: expected 404, got {response.status_code}"
            )

    preflight = client.options(
        "/api/health",
        headers={
            "Origin": "http://evil.example",
            "Access-Control-Request-Method": "GET",
        },
    )
    if preflight.status_code != 404:
        raise SystemExit(f"FAIL: CORS preflight: expected 404, got {preflight.status_code}")

    print("memory_guard selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
