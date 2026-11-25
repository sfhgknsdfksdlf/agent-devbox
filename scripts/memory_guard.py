#!/usr/bin/env python3
"""Loopback-only allowlisting front end for mcp-memory-service.

The dashboard, static assets, configuration/credential API and OAuth surface of
mcp-memory-service are not needed by an OpenCode agent. This process serves the
installed FastAPI application behind an outermost allowlist middleware that
answers 404 for anything outside a small allowlist before the upstream handler
can run. It binds uvicorn on 127.0.0.1 only -- never 0.0.0.0 -- with WebSocket
support disabled, because the HTTP middleware cannot guard WebSocket upgrades.

Route stripping is deliberately NOT used: FastAPI 0.165 represents included
routers as ``_IncludedRouter`` objects with no ``path``/``methods``, so
shape-based stripping deletes the whole API (health, mcp, memories). The
middleware is the security boundary; the upstream route table stays intact.

The allowlist (see ``is_allowed``) covers exactly:

  * ``POST /mcp`` (JSON-RPC endpoint used by the managed remote MCP entry);
  * ``GET /mcp`` (streamable-HTTP discovery probe; harmless when unimplemented);
  * ``POST /api/memories`` and ``DELETE /api/memories/<hash>`` (OpenCode plugin);
  * ``POST /api/search``, ``POST /api/search/by-tag`` (OpenCode plugin);
  * ``POST /api/harvest`` (OpenCode plugin's optional session harvest);
  * ``GET /api/health`` and ``GET /api/health/detailed`` (supervisor readiness).

Nothing else is reachable: ``/`` (dashboard), ``/static/*``,
``/api/config/credentials`` (writes cwd/.env), ``/api/configuration/*``,
``/api/oauth/*`` and the OpenAPI/docs routes all return 404.

``is_allowed`` is deliberately pure and imports no third-party module, so the
allowlist can be unit-tested on a host where mcp-memory-service is not installed.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# (method, normalized path) pairs the runtime exposes.
_ALLOWED_STATIC = frozenset(
    {
        ("POST", "/mcp"),
        # Streamable-HTTP clients may probe GET before POST; the upstream app has
        # no GET /mcp handler, so this falls through to its own 405/404.
        ("GET", "/mcp"),
        ("POST", "/api/memories"),
        ("POST", "/api/search"),
        ("POST", "/api/search/by-tag"),
        ("POST", "/api/harvest"),
        ("GET", "/api/health"),
        ("GET", "/api/health/detailed"),
    }
)

# DELETE /api/memories/<hash>. The guard checks request paths, not route
# templates, so only the real hash charset is accepted (no ``{...}`` form).
_MEMORY_DELETE = re.compile(r"^/api/memories/[A-Za-z0-9_.-]{1,128}$")

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


def _normalize_path(path: str) -> str | None:
    """Normalize a request path; return None for anything structurally unsafe."""
    if not isinstance(path, str) or not path.startswith("/"):
        return None
    if "\x00" in path or "\\" in path or "//" in path:
        return None
    if "/./" in path or "/../" in path:
        return None
    if len(path) > 1:
        path = path.rstrip("/")
        if not path:
            return None
    return path


def is_allowed(method: str, path: str) -> bool:
    """Return True only for the exact (method, path) pairs the runtime needs."""
    if not isinstance(method, str):
        return False
    normalized = _normalize_path(path)
    if normalized is None:
        return False
    method = method.upper()
    if (method, normalized) in _ALLOWED_STATIC:
        return True
    if method == "DELETE" and _MEMORY_DELETE.match(normalized):
        return True
    return False


def install_middleware(app) -> None:
    """404 disallowed requests before routing (outermost HTTP middleware)."""
    from starlette.responses import JSONResponse

    @app.middleware("http")
    async def _allowlist_guard(request, call_next):
        if not is_allowed(request.method, request.url.path):
            return JSONResponse({"detail": "Not Found"}, status_code=404)
        return await call_next(request)


def build_app(upstream_app=None):
    """Import the installed app, install the allowlist, and return it.

    ``upstream_app`` is a test seam: production imports the installed
    mcp-memory-service app, while the build-time selftest passes a real FastAPI
    app with ``include_router()`` so the FastAPI 0.165 ``_IncludedRouter``
    representation is covered.
    """
    if upstream_app is None:
        # Imported lazily: importing this module must not require the package.
        from mcp_memory_service.web.app import app as upstream_app

    install_middleware(upstream_app)
    sys.stderr.write("memory_guard: allowlist active\n")
    sys.stderr.flush()
    return upstream_app


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args(argv)

    if args.host not in _LOOPBACK_HOSTS:
        sys.stderr.write(
            f"memory_guard: refusing non-loopback host {args.host!r}; bind 127.0.0.1 only\n"
        )
        return 2
    if not 1 <= args.port <= 65535:
        sys.stderr.write(f"memory_guard: invalid port {args.port}\n")
        return 2

    # Enforce the security posture before the package's config module is imported.
    os.environ["MCP_HTTP_HOST"] = "127.0.0.1"
    os.environ["MCP_MDNS_ENABLED"] = "false"
    os.environ["MCP_OAUTH_ENABLED"] = "false"
    os.environ["MCP_ALLOW_ANONYMOUS_ACCESS"] = "false"

    if not os.environ.get("MCP_API_KEY"):
        sys.stderr.write(
            "memory_guard: MCP_API_KEY is required (anonymous access is disabled)\n"
        )
        return 2

    app = build_app()

    import uvicorn

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=args.port,
        log_level="info",
        access_log=False,
        ws="none",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
