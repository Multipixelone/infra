import json
import os
from pathlib import Path

import pytest
from games_dashboard.models import Manifest


@pytest.fixture
def manifest_data():
    filename = os.environ.get("GAMES_DASHBOARD_MOCK_MANIFEST")
    if not filename:
        pytest.fail(
            "run pytest in nix develop .#games-dashboard for the real Nix fixture"
        )
    return json.loads(Path(filename).read_text())


@pytest.fixture
def manifest(manifest_data):
    return Manifest.model_validate(manifest_data)
