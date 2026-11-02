"""Focused checks for the vendored OmniRoute skill and its HM deployment."""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unittest
from pathlib import Path
from urllib.parse import unquote

import yaml

ARGS = None

EXPECTED_FILES = {
    "references/omni-mcp.md": (
        "dist/skills/omni-mcp/SKILL.md",
        "a871defe59365d76ed8f4486ed3f1ba0786297f2746dc7eb9cef1ca8870c6715",
    ),
    "references/omni-providers/reference.md": (
        "dist/skills/omni-providers/SKILL.md",
        "3082e241c135b820aa6323f40b9b3c9c62552ed738f5a662c1bde917cd1bccbd",
    ),
    "references/omni-providers/references/endpoints.md": (
        "dist/skills/omni-providers/references/endpoints.md",
        "89a80d10dbdbd31ea898c5fb7b290e67af21933a0b654d52c6b43beac1fb3799",
    ),
    "references/omni-usage-logs.md": (
        "dist/skills/omni-usage-logs/SKILL.md",
        "a41b21aeba9a3f083dd945ace7cd798c388a9f411db4da8319fad3f9652271e4",
    ),
    "references/omni-context-rtk.md": (
        "dist/skills/omni-context-rtk/SKILL.md",
        "7fc1f159a9600a9d2c09c8fae3e2212bba3499864eb584c78d1f9a62c55324a6",
    ),
    "LICENSE": (
        "LICENSE",
        "5f3caa52b2c2ce5dfb40c85404a370d23b6dc3e26a1447d17dc7e56f773b91de",
    ),
}
SAFETY_DOC = "references/operating-boundaries.md"

LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def split_frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    return yaml.safe_load(text[4:end])


def prose_lines(text):
    """Yield lines outside fenced code blocks."""
    fenced = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield line


def slugify(heading):
    # GitHub-style anchor slug.
    heading = re.sub(r"<[^>]+>", "", heading).strip().lower()
    heading = re.sub(r"[^\w\- ]", "", heading)
    return heading.replace(" ", "-")


def anchors(text):
    seen = {}
    result = set()
    for line in prose_lines(text):
        match = HEADING_RE.match(line)
        if not match:
            continue
        slug = slugify(match.group(2))
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    return result


def links(text):
    for line in prose_lines(text):
        yield from LINK_RE.findall(line)


def is_external(target):
    return re.match(r"^[a-z][a-z0-9+.-]*:", target, re.IGNORECASE) is not None


class SourceTree(unittest.TestCase):
    def setUp(self):
        self.root = Path(ARGS.source)
        self.files = sorted(
            p.relative_to(self.root).as_posix()
            for p in self.root.rglob("*")
            if p.is_file() or p.is_symlink()
        )

    def test_immutable_store_source(self):
        self.assertTrue(str(self.root).startswith("/nix/store/"), self.root)
        for rel in self.files:
            path = self.root / rel
            self.assertFalse(path.is_symlink(), rel)
            self.assertFalse(path.stat().st_mode & stat.S_IWUSR, f"{rel} is writable")

    def test_exact_file_set(self):
        expected = set(EXPECTED_FILES) | {"SKILL.md", "provenance.json", SAFETY_DOC}
        self.assertEqual(set(self.files), expected)

    def test_provenance(self):
        prov = json.loads((self.root / "provenance.json").read_text())
        self.assertEqual(prov["package"], "omniroute")
        self.assertEqual(prov["version"], "3.8.52")
        self.assertEqual(prov["license"], "MIT")
        self.assertNotIn("gitHead", prov)
        entries = prov["files"]
        self.assertEqual(len(entries), 6)
        destinations = [e["destination"] for e in entries]
        self.assertEqual(len(set(destinations)), 6, "duplicate destinations")
        for entry in entries:
            dest = entry["destination"]
            self.assertIn(dest, EXPECTED_FILES)
            source, digest = EXPECTED_FILES[dest]
            self.assertEqual(entry["source"], source)
            self.assertEqual(entry["sha256"], digest)
            for rel in (entry["source"], dest):
                self.assertFalse(rel.startswith("/"), rel)
                self.assertNotIn("..", Path(rel).parts, rel)
            self.assertEqual(sha256(self.root / dest), digest, dest)
        self.assertIn("MIT", (self.root / "LICENSE").read_text())

    def test_single_discoverable_skill(self):
        skill_files = [f for f in self.files if Path(f).name == "SKILL.md"]
        self.assertEqual(skill_files, ["SKILL.md"])
        meta = split_frontmatter((self.root / "SKILL.md").read_text())
        self.assertIsInstance(meta, dict)
        self.assertEqual(meta.get("name"), "omniroute")
        self.assertIsInstance(meta.get("description"), str)
        self.assertTrue(meta["description"].strip())

    def test_copied_docs_keep_upstream_frontmatter(self):
        for dest, (source, _) in EXPECTED_FILES.items():
            if not source.endswith("/SKILL.md"):
                continue
            meta = split_frontmatter((self.root / dest).read_text())
            self.assertIsInstance(meta, dict, dest)
            self.assertTrue(meta.get("name", "").startswith("omni-"), dest)

    def test_no_budget_or_cli_docs(self):
        for rel in self.files:
            lowered = rel.lower()
            self.assertNotIn("budget", lowered, rel)
            self.assertIsNone(re.search(r"(^|[/_-])cli([/_.-]|$)", lowered), rel)

    def test_safety_doc_referenced_first(self):
        text = (self.root / "SKILL.md").read_text()
        refs = [t for t in links(text) if t.startswith("references/")]
        self.assertTrue(refs)
        self.assertEqual(refs[0].split("#")[0], SAFETY_DOC)

    def test_link_closure(self):
        markdown = {rel for rel in self.files if rel.endswith(".md")}
        texts = {rel: (self.root / rel).read_text() for rel in markdown}
        heading_anchors = {rel: anchors(text) for rel, text in texts.items()}
        reachable, queue = set(), ["SKILL.md"]
        anchored = 0
        while queue:
            current = queue.pop()
            if current in reachable:
                continue
            reachable.add(current)
            for target in links(texts[current]):
                self.assertFalse(
                    is_external(target) and target.startswith("file:"), target
                )
                if is_external(target):
                    continue
                path_part, _, fragment = target.partition("#")
                if path_part:
                    self.assertFalse(path_part.startswith("/"), f"{current}: {target}")
                    resolved = os.path.normpath(
                        (Path(current).parent / unquote(path_part)).as_posix()
                    )
                    self.assertFalse(
                        resolved.startswith(".."), f"{current}: {target} escapes skill"
                    )
                    self.assertIn(resolved, self.files, f"{current}: broken {target}")
                else:
                    resolved = current
                if fragment:
                    anchored += 1
                    self.assertIn(
                        unquote(fragment),
                        heading_anchors.get(resolved, set()),
                        f"{current}: missing anchor {target}",
                    )
                if resolved in markdown:
                    queue.append(resolved)
        self.assertEqual(
            reachable, markdown, "markdown files unreachable from SKILL.md"
        )
        # Provider docs rely on in-page and cross-file anchors.
        self.assertGreater(anchored, 0)


def glob_matches(pattern, path):
    """Conservative treefmt-style glob match (also tries the basename)."""
    regex = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            regex += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            regex += ".*"
            i += 2
        elif pattern[i] == "*":
            regex += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            regex += "[^/]"
            i += 1
        else:
            regex += re.escape(pattern[i])
            i += 1
    compiled = re.compile(regex + r"\Z")
    return bool(compiled.match(path) or compiled.match(path.rsplit("/", 1)[-1]))


class FormatterPreservation(unittest.TestCase):
    """Byte-preserved upstream files must be excluded from treefmt; authored ones not."""

    def setUp(self):
        self.meta = json.loads(Path(ARGS.metadata).read_text())
        self.skill_dir = self.meta["skillDir"]
        self.excludes = self.meta["treefmtExcludes"]
        prov = json.loads((Path(ARGS.source) / "provenance.json").read_text())
        self.preserved = {f"{self.skill_dir}/{e['destination']}" for e in prov["files"]}

    def test_preserved_set_matches_provenance(self):
        self.assertEqual(set(self.meta["preservedFiles"]), self.preserved)
        self.assertEqual(
            self.preserved, {f"{self.skill_dir}/{rel}" for rel in EXPECTED_FILES}
        )

    def test_preserved_files_excluded_exactly(self):
        for path in sorted(self.preserved):
            self.assertIn(path, self.excludes, f"{path} not explicitly excluded")

    def test_authored_files_still_formatted(self):
        for rel in ("SKILL.md", SAFETY_DOC, "provenance.json"):
            path = f"{self.skill_dir}/{rel}"
            hits = [p for p in self.excludes if glob_matches(p, path)]
            self.assertEqual(hits, [], f"{path} unexpectedly excluded by {hits}")

    def test_no_broad_skill_exclude(self):
        for pattern in self.excludes:
            if "omniroute" in pattern:
                self.assertIn(pattern, self.preserved, f"broad exclude {pattern}")


class Deployment(unittest.TestCase):
    def setUp(self):
        self.meta = json.loads(Path(ARGS.metadata).read_text())
        self.source = os.path.realpath(ARGS.source)
        self.parent = Path(ARGS.parent_skills)
        self.enabled = Path(ARGS.enabled_home)
        self.disabled = Path(ARGS.disabled_home)
        self.non_link = Path(ARGS.non_link_home)

    def assert_link(self, home, target):
        path = home / target
        self.assertTrue(path.is_symlink(), f"{target} is not a single link")
        self.assertEqual(os.path.realpath(path), self.source, target)

    def test_declared_sources(self):
        self.assertEqual(os.path.realpath(self.meta["source"]), self.source)
        expectations = {
            ("enabled", "opencode"): 1,
            ("enabled", "openclaw"): 1,
            ("disabled", "opencode"): 0,
            ("disabled", "openclaw"): 1,
            ("nonLink", "opencode"): 1,
            ("nonLink", "openclaw"): 0,
        }
        for (state, key), count in expectations.items():
            entries = self.meta[state][key]
            self.assertEqual(len(entries), count, f"{state}.{key}")
            for entry in entries:
                self.assertEqual(entry["source"], self.meta["source"])
                self.assertFalse(entry["recursive"], f"{state}.{key}")
                self.assertFalse(entry["force"], f"{state}.{key}")

    def test_no_overlap(self):
        for state in ("enabled", "disabled", "nonLink"):
            targets = self.meta[state]["targets"]
            self.assertEqual(len(targets), len(set(targets)), state)
            for ours in (self.meta["opencodeTarget"], self.meta["openclawTarget"]):
                nested = [t for t in targets if t.startswith(ours + "/")]
                self.assertEqual(nested, [], f"{state}: overlaps {ours}")
        self.assertFalse((self.parent / "omniroute").exists())
        parent = self.meta["enabled"]["opencodeParent"]
        self.assertEqual(len(parent), 1)
        self.assertTrue(parent[0]["recursive"])
        self.assertEqual(self.meta["disabled"]["opencodeParent"], [])

    def test_enabled_tree(self):
        self.assert_link(self.enabled, self.meta["opencodeTarget"])
        self.assert_link(self.enabled, self.meta["openclawTarget"])
        skills = self.enabled / ".config/opencode/skills"
        self.assertFalse(skills.is_symlink(), "parent skills must stay recursive")
        for child in self.parent.iterdir():
            self.assertTrue(
                (skills / child.name).exists(), f"lost parent skill {child.name}"
            )
        self.assertTrue((skills / "fixture-child/SKILL.md").exists())
        self.assertTrue(
            (self.enabled / ".openclaw/workspace/skills/fixture-claw/SKILL.md").exists()
        )
        self.assertTrue((skills / "omniroute/SKILL.md").is_file())

    def test_non_link_scope(self):
        self.assert_link(self.non_link, self.meta["opencodeTarget"])
        self.assertFalse(os.path.lexists(self.non_link / self.meta["openclawTarget"]))

    def test_disabled_tree(self):
        self.assertFalse((self.disabled / self.meta["opencodeTarget"]).exists())
        self.assert_link(self.disabled, self.meta["openclawTarget"])
        for child in self.parent.iterdir():
            self.assertFalse(
                (self.disabled / ".config/opencode/skills" / child.name).exists()
            )
        self.assertTrue(
            (self.disabled / ".config/opencode/skills/fixture-child/SKILL.md").exists()
        )
        self.assertTrue(
            (
                self.disabled / ".openclaw/workspace/skills/fixture-claw/SKILL.md"
            ).exists()
        )


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    for name in (
        "source",
        "parent-skills",
        "metadata",
        "enabled-home",
        "disabled-home",
        "non-link-home",
    ):
        parser.add_argument(f"--{name}", required=True)
    ARGS, rest = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)


if __name__ == "__main__":
    main()
