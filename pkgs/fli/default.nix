{
  lib,
  buildPythonApplication,
  fetchPypi,
  hatchling,
  # core runtime deps
  babel,
  curl-cffi,
  httpx,
  plotext,
  pydantic,
  python-dotenv,
  ratelimit,
  tenacity,
  typer,
  # `mcp` extra — required by the fli-mcp / fli-mcp-http entrypoints
  fastapi,
  fastmcp,
  pydantic-settings,
  uvicorn,
}:

# Upstream PyPI name is `flights`; the repo, CLI (`fli`) and MCP server
# (`fli-mcp`) are all named `fli`. Packaged as an application because we only
# consume its entrypoints, not the library. No API key/auth needed — it queries
# Google Flights' internal API directly.
buildPythonApplication rec {
  pname = "flights";
  version = "0.9.0";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-/e9s2JJIL7wXFxRQ1utRNB9IrRBSjE9x/pdnevsPBTM=";
  };

  pyproject = true;
  build-system = [ hatchling ];

  dependencies = [
    babel
    curl-cffi
    httpx
    plotext
    pydantic
    python-dotenv
    ratelimit
    tenacity
    typer
    # bundled unconditionally: fli-mcp is the whole point of packaging this
    fastapi
    fastmcp
    pydantic-settings
    uvicorn
  ];

  # The sdist does ship tests/, but they hit Google Flights' live API — no
  # network in the sandbox, and they'd be flaky even with it.
  doCheck = false;

  # `fli.mcp._entry` only imports `sys`; it defers the real import into a
  # try/except ModuleNotFoundError, so it passes even with the `mcp` extra
  # missing entirely. `fli.mcp.server` is what actually pulls fastmcp /
  # mcp.types / pydantic-settings, so that's the import worth checking.
  pythonImportsCheck = [
    "fli"
    "fli.mcp.server"
  ];

  meta = {
    description = "Google Flights API wrapper — CLI (fli) and MCP server (fli-mcp)";
    homepage = "https://github.com/punitarani/fli";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ Multipixelone ];
    mainProgram = "fli-mcp";
  };
}
