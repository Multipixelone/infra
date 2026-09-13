from __future__ import annotations

import signal
import socket
import threading
from contextlib import contextmanager

from .errors import Configuration


class DeadlineExpired(Exception):
    pass


def closing_create_connection(
    address,
    timeout=socket._GLOBAL_DEFAULT_TIMEOUT,
    source_address=None,
    *,
    all_errors=False,
):
    """socket.create_connection with BaseException-safe per-address cleanup."""
    host, port = address
    errors = []
    for family, socktype, protocol, _, sockaddr in socket.getaddrinfo(
        host, port, 0, socket.SOCK_STREAM
    ):
        candidate = None
        try:
            candidate = socket.socket(family, socktype, protocol)
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                candidate.settimeout(timeout)
            if source_address:
                candidate.bind(source_address)
            candidate.connect(sockaddr)
            return candidate
        except BaseException as exc:
            if candidate is not None:
                candidate.close()
            if not isinstance(exc, OSError):
                raise
            if not all_errors:
                errors.clear()
            errors.append(exc)
    if all_errors and errors:
        raise ExceptionGroup("create_connection failed", errors)
    if errors:
        raise errors[-1]
    raise OSError("getaddrinfo returned no addresses")


@contextmanager
def absolute_deadline(seconds: float):
    """Interrupt a blocking POSIX operation at one wall-clock deadline."""
    if (
        threading.current_thread() is not threading.main_thread()
        or not hasattr(signal, "setitimer")
        or not hasattr(signal, "SIGALRM")
    ):
        raise Configuration(
            "absolute HTTP deadlines require the main thread on this platform"
        )
    if seconds <= 0:
        raise Configuration("HTTP deadline must be positive")
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    if previous_delay or previous_interval:
        raise Configuration(
            "absolute HTTP deadline cannot replace an existing SIGALRM timer"
        )

    def expire(signum, frame):
        raise DeadlineExpired("HTTP deadline exceeded")

    handler_installed = False
    try:
        signal.signal(signal.SIGALRM, expire)
        handler_installed = True
        signal.setitimer(signal.ITIMER_REAL, seconds)
        yield
    finally:
        if handler_installed:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
