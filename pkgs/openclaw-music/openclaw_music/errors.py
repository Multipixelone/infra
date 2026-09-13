from __future__ import annotations


class MusicError(Exception):
    def __init__(
        self,
        code: int,
        message: str,
        *,
        symbol: str,
        retryable: bool = False,
        detail=None,
    ):
        super().__init__(message)
        self.code = code
        self.message = message
        self.symbol = symbol
        self.retryable = retryable
        self.detail = detail


class InvalidInput(MusicError):
    def __init__(self, message: str, detail=None):
        super().__init__(2, message, symbol="invalid_input", detail=detail)


class Unknown(MusicError):
    def __init__(self, message: str):
        super().__init__(3, message, symbol="unknown")


class Conflict(MusicError):
    def __init__(self, message: str):
        super().__init__(4, message, symbol="conflict")


class Temporary(MusicError):
    def __init__(self, message: str, detail=None):
        super().__init__(
            5, message, symbol="temporary_unavailable", retryable=True, detail=detail
        )


class Configuration(MusicError):
    def __init__(self, message: str):
        super().__init__(6, message, symbol="configuration")


class BackendPermanent(MusicError):
    def __init__(self, message: str, detail=None):
        super().__init__(7, message, symbol="backend_permanent", detail=detail)


class BackendNotFound(MusicError):
    """A GET proved that a named backend resource does not exist."""

    def __init__(self, message: str):
        super().__init__(3, message, symbol="backend_not_found")


class BackendTransient(MusicError):
    def __init__(self, message: str, detail=None):
        super().__init__(
            5, message, symbol="backend_transient", retryable=True, detail=detail
        )


class BackendUncertain(MusicError):
    """A mutation may have reached the backend but its result was lost."""

    def __init__(self, message: str, detail=None):
        super().__init__(8, message, symbol="backend_uncertain", detail=detail)


class BeetsNoImport(MusicError):
    def __init__(
        self, message: str = "beets completed without a verified import receipt"
    ):
        super().__init__(7, message, symbol="beets_no_import")
