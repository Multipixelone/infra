"""Stable CLI failures shared by human and JSON output."""


class ListenError(Exception):
    def __init__(self, code, message, exit_code=66, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code
        self.details = details


def invalid(message):
    return ListenError("invalid_arguments", message, 64)
