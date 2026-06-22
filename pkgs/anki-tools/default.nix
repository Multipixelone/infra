{
  lib,
  buildPythonApplication,
  setuptools,
  genanki,
}:
buildPythonApplication {
  pname = "anki-tools";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = [ setuptools ];

  # Only build_deck needs genanki; parse/add/connect are pure stdlib. They all
  # share one environment, so genanki is propagated for the whole package.
  propagatedBuildInputs = [ genanki ];

  doCheck = false;

  meta = {
    description = "Build .apkg decks and push cards to a running Anki from a shared cards.json schema";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ Multipixelone ];
    mainProgram = "anki-build-deck";
  };
}
