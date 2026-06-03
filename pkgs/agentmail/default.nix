{
  lib,
  buildPythonPackage,
  fetchPypi,
  httpx,
  pydantic,
  pydantic-core,
  typing-extensions,
  websockets,
  poetry-core,
}:

buildPythonPackage rec {
  pname = "agentmail";
  version = "0.5.1";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-SUGN3NcyscSBwFdA400RT8oU99ChRdeeAw918bsMg0Q";
  };

  pyproject = true;

  build-system = [ poetry-core ];

  # Upstream pyproject.toml places description, authors, keywords, license, homepage
  # as orphaned keys after [build-system] instead of under [project].
  # poetry-core (the upstream build backend) rejects these as unknown build-system properties.
  # Patch: remove the orphaned keys and add them under [project].
  postPatch = ''
        # Remove orphaned keys after [build-system]
        sed -i '/^description = /d; /^authors = /d; /^keywords = /d; /^license = /d; /^homepage = /d' pyproject.toml

        # Add metadata under [project]
        sed -i '/^\[project\]/a\
    description = "The email inbox API for AI agents. Send, receive, reply, and manage threaded email conversations programmatically."\
    authors = [{name = "AgentMail", email = "support@agentmail.cc"}]\
    keywords = ["email", "ai", "agent", "inbox", "api"]\
    license = "MIT"' pyproject.toml
  '';

  dependencies = [
    httpx
    pydantic
    pydantic-core
    typing-extensions
    websockets
  ];

  # No tests in PyPI tarball
  doCheck = false;

  pythonImportsCheck = [ "agentmail" ];

  meta = with lib; {
    description = "Python SDK for the AgentMail email API";
    homepage = "https://github.com/agentmail-to/agentmail-python";
    license = licenses.mit;
    maintainers = with maintainers; [ Multipixelone ];
  };
}
