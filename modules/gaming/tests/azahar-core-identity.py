"""Check the installed libretro ABI without initializing a core or loading content."""

import ctypes
import json
import sys


class SystemInfo(ctypes.Structure):
    _fields_ = [
        ("library_name", ctypes.c_char_p),
        ("library_version", ctypes.c_char_p),
        ("valid_extensions", ctypes.c_char_p),
        ("need_fullpath", ctypes.c_bool),
        ("block_extract", ctypes.c_bool),
    ]


def main():
    library_path, expected_version = sys.argv[1:]
    core = ctypes.CDLL(library_path)
    for symbol in (
        "retro_init",
        "retro_deinit",
        "retro_run",
        "retro_load_game",
        "retro_set_environment",
        "retro_get_system_info",
        "retro_api_version",
    ):
        getattr(core, symbol)

    core.retro_api_version.restype = ctypes.c_uint
    assert core.retro_api_version() == 1, "unexpected libretro ABI version"
    core.retro_get_system_info.argtypes = [ctypes.POINTER(SystemInfo)]
    core.retro_get_system_info.restype = None
    info = SystemInfo()
    core.retro_get_system_info(ctypes.byref(info))
    name = info.library_name.decode()
    version = info.library_version.decode()
    extensions = info.valid_extensions.decode().split("|")
    assert name == "Azahar", f"wrong core: {name!r}"
    assert expected_version in version, f"wrong core version: {version!r}"
    assert "cci" in extensions, f"unexpected extensions: {extensions!r}"
    print(json.dumps({"library": library_path, "name": name, "version": version}))


if __name__ == "__main__":
    main()
