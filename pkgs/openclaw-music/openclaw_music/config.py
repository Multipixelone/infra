from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from .errors import Configuration
from .ledger import Ledger
from .resolver import MusicBrainzClient, Resolver
from .slskd import SlskdClient, api_key_from_file
from .validation import AudioValidator


def _absolute(value: str | None, name: str, *, executable: bool = False) -> str:
    if not value or not Path(value).is_absolute() or "\x00" in value:
        raise Configuration(f"{name} must be an absolute trusted path")
    if executable and not Path(value).is_file():
        raise Configuration(f"{name} is not a file")
    return value


def _loopback(url: str) -> str:
    parsed = urlparse(url)
    try:
        loopback = ipaddress.ip_address(parsed.hostname or "").is_loopback
    except ValueError:
        loopback = False
    if (
        parsed.scheme not in {"http", "https"}
        or not loopback
        or parsed.path not in {"", "/"}
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        raise Configuration("slskd origin must be loopback HTTP(S)")
    return url.rstrip("/")


@dataclass(frozen=True)
class TrustedConfig:
    ledger_root: str
    staging_root: str
    download_root: str
    mb_user_agent: str
    slskd_url: str
    slskd_secret: str
    ffprobe: str
    ffmpeg: str
    max_files: int = 100
    max_bytes: int = 4_000_000_000
    destination_mode: str = "BATCH_JOB"
    collision_policy: str = "batch"
    transport_isolated: bool = False
    quality_default: str = "lossless-preferred"
    library_root: str | None = None
    beets_executable: str | None = None
    beets_config: str | None = None
    beets_lock: str | None = None
    beets_home: str | None = None
    beets_path: str | None = None
    beets_cache: str | None = None

    def __post_init__(self) -> None:
        _loopback(self.slskd_url)
        if self.destination_mode != "BATCH_JOB" or self.collision_policy != "batch":
            raise Configuration("unsupported slskd destination semantics")
        if self.max_files < 1 or self.max_bytes < 1:
            raise Configuration("invalid resource limits")
        if self.quality_default not in {"lossless", "lossless-preferred"}:
            raise Configuration("invalid default quality profile")
        if self.library_root is not None:
            _absolute(self.library_root, "library root")
        beets_paths = (
            self.beets_executable,
            self.beets_config,
            self.beets_lock,
            self.beets_home,
            self.beets_path,
            self.beets_cache,
        )
        if any(beets_paths) and (not all(beets_paths) or not self.library_root):
            raise Configuration("all beets adapter paths are required together")
        if all(beets_paths):
            _absolute(self.beets_executable, "beets executable", executable=True)
            _absolute(self.beets_config, "beets config")
            _absolute(self.beets_lock, "beets lock")
            _absolute(self.beets_home, "beets home")
            _absolute(self.beets_cache, "beets cache")
            if any(
                not Path(entry).is_absolute() for entry in self.beets_path.split(":")
            ):
                raise Configuration("beets PATH entries must be absolute")

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        return cls(
            _absolute(env.get("OPENCLAW_MUSIC_LEDGER"), "ledger"),
            _absolute(env.get("OPENCLAW_MUSIC_STAGING"), "staging"),
            _absolute(env.get("OPENCLAW_MUSIC_DOWNLOAD_ROOT"), "download root"),
            env.get("OPENCLAW_MUSIC_MB_USER_AGENT")
            or (_ for _ in ()).throw(Configuration("MusicBrainz User-Agent required")),
            _loopback(env.get("OPENCLAW_MUSIC_SLSKD_URL", "")),
            _absolute(env.get("OPENCLAW_MUSIC_SLSKD_SECRET"), "slskd secret"),
            _absolute(env.get("OPENCLAW_MUSIC_FFPROBE"), "ffprobe", executable=True),
            _absolute(env.get("OPENCLAW_MUSIC_FFMPEG"), "ffmpeg", executable=True),
            transport_isolated=env.get("OPENCLAW_MUSIC_TRANSPORT_ISOLATED") == "1",
            quality_default=env.get(
                "OPENCLAW_MUSIC_QUALITY_DEFAULT", "lossless-preferred"
            ),
            library_root=_absolute(
                env.get("OPENCLAW_MUSIC_LIBRARY_ROOT"), "library root"
            ),
            beets_executable=env.get("OPENCLAW_MUSIC_BEETS"),
            beets_config=env.get("OPENCLAW_MUSIC_BEETS_CONFIG"),
            beets_lock=env.get("OPENCLAW_MUSIC_BEETS_LOCK"),
            beets_home=env.get("OPENCLAW_MUSIC_BEETS_HOME"),
            beets_path=env.get("OPENCLAW_MUSIC_BEETS_PATH"),
            beets_cache=env.get("OPENCLAW_MUSIC_BEETS_CACHE"),
        )


def production_factory(
    config: TrustedConfig,
    *,
    mb_transport=None,
    slskd_transport=None,
    run=None,
    importer=None,
    indexer=None,
):
    """Production composition; network boundaries remain injectable for offline tests."""
    from .jobs import JobService

    validator = (
        AudioValidator(config.ffprobe, config.ffmpeg, run=run)
        if run is not None
        else AudioValidator(config.ffprobe, config.ffmpeg)
    )
    if importer is None and config.beets_executable:
        from .importer import DirectBeetsImportAdapter

        importer = DirectBeetsImportAdapter(
            config.beets_executable,
            config.beets_config,
            config.beets_lock,
            config.staging_root,
            config.library_root,
            config.beets_home,
            config.beets_path,
            config.beets_cache,
            validator=validator,
        )
    return JobService(
        Ledger(config.ledger_root),
        Resolver(MusicBrainzClient(config.mb_user_agent, transport=mb_transport)),
        SlskdClient(
            config.slskd_url,
            api_key_from_file(config.slskd_secret),
            transport=slskd_transport,
        ),
        validator,
        config,
        importer=importer,
        indexer=indexer,
    )
