# -*- coding: utf-8 -*-
"""
servicios_pesa/services/http_client.py
Pool persistente de conexiones HTTP/HTTPS hacia Render para evitar handshakes
TLS repetitivos en descargas de PDF, pings y consultas de sincronizacion.
"""
from __future__ import annotations

import json
import threading
from typing import Any, Optional

try:
    import requests
    from requests.adapters import HTTPAdapter
    _HAS_REQUESTS = True
except ImportError:
    requests = None  # type: ignore[assignment]
    HTTPAdapter = None  # type: ignore[assignment]
    _HAS_REQUESTS = False

try:
    import urllib3
    _HAS_URLLIB3 = True
except ImportError:
    urllib3 = None  # type: ignore[assignment]
    _HAS_URLLIB3 = False

import urllib.request
import urllib.error

_lock = threading.Lock()
_session = None
_pool_manager = None


def get_http_session():
    """Retorna una instancia singleton de requests.Session con connection pool."""
    global _session
    if not _HAS_REQUESTS:
        return None
    if _session is None:
        with _lock:
            if _session is None:
                s = requests.Session()
                adapter = HTTPAdapter(pool_connections=10, pool_maxsize=10)
                s.mount("https://", adapter)
                s.mount("http://", adapter)
                s.headers.update({"User-Agent": "PesaDesktop/1.0"})
                _session = s
    return _session


def _get_urllib3_pool():
    global _pool_manager
    if not _HAS_URLLIB3:
        return None
    if _pool_manager is None:
        with _lock:
            if _pool_manager is None:
                _pool_manager = urllib3.PoolManager(num_pools=8, maxsize=10)
    return _pool_manager


def http_request(
    method: str,
    url: str,
    *,
    headers: Optional[dict[str, str]] = None,
    data: Optional[bytes] = None,
    json_body: Any = None,
    timeout: float = 12.0,
) -> tuple[int, dict[str, str], bytes]:
    """
    Ejecuta una peticion HTTP reutilizando conexiones TCP/TLS cuando es posible.
    Retorna `(status_code, lower_headers_dict, body_bytes)`.
    Lanza `urllib.error.HTTPError` cuando status >= 400 para mantener compatibilidad.
    """
    req_headers = {"User-Agent": "PesaDesktop/1.0"}
    if headers:
        req_headers.update(headers)

    session = get_http_session()
    if session is not None:
        kwargs: dict[str, Any] = {"headers": req_headers, "timeout": timeout}
        if json_body is not None:
            kwargs["json"] = json_body
        elif data is not None:
            kwargs["data"] = data
        resp = session.request(method.upper(), url, **kwargs)
        body = resp.content or b""
        hdrs = {str(k).lower(): str(v) for k, v in resp.headers.items()}
        if resp.status_code >= 400:
            raise urllib.error.HTTPError(url, resp.status_code, resp.reason or "", resp.headers, None)
        return resp.status_code, hdrs, body

    pool = _get_urllib3_pool()
    if pool is not None:
        body_bytes = data
        if json_body is not None:
            body_bytes = json.dumps(json_body).encode("utf-8")
            req_headers.setdefault("Content-Type", "application/json")
        resp = pool.request(
            method.upper(),
            url,
            body=body_bytes,
            headers=req_headers,
            timeout=timeout,
        )
        hdrs = {str(k).lower(): str(v) for k, v in resp.headers.items()}
        if resp.status >= 400:
            raise urllib.error.HTTPError(url, resp.status, "", resp.headers, None)
        return int(resp.status), hdrs, resp.data or b""

    body_bytes = data
    if json_body is not None:
        body_bytes = json.dumps(json_body).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body_bytes, headers=req_headers, method=method.upper())
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        hdrs = {str(k).lower(): str(v) for k, v in resp.headers.items()}
        return int(resp.status), hdrs, resp.read()
