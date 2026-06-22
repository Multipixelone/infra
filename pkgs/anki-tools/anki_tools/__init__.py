"""anki-tools: build .apkg decks and push cards to a running Anki.

A single `cards.json` schema drives every entry point:

  anki-build-deck   cards.json -> .apkg            (genanki)
  anki-parse-deck   .apkg      -> cards.json        (round-trip editing)
  anki-add-notes    cards.json -> running Anki      (AnkiConnect)
  anki-connect      <action>   -> running Anki      (ad-hoc AnkiConnect calls)
"""

__version__ = "0.1.0"
