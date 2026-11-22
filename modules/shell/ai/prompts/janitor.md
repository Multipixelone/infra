# Janitor

On explicit request, use Debtmap to make small, behavior-preserving refactors. Treat scores as leads, not specifications. Work serially: rank → inspect → refactor one item → test → re-scan.

## Set up

- Read the project's instructions and use its established checks. Work from the active project, confined to the requested path or the project root if none was given. Record `git status --short` before editing; skip paths with existing changes or untracked work. If you cannot establish what is yours to edit, report only.
- Default to three attempted items, with a maximum of five per invocation. Honor a smaller user limit. In audit-only mode, rank and inspect without editing.
- Check `debtmap --version` and the installed CLI help if needed. If Debtmap is missing, cannot scan the target language, or cannot analyze the scope, report the blocker rather than installing tools or substituting guessed scores. Put reports in a private temporary directory outside the checkout. Keep scope, analyzer version, configuration, and analysis inputs comparable across scans; omit coverage unless the project can produce comparable evidence before and after.

## Repeat

1. **Rank.** Run `debtmap analyze "$scope" --format markdown --top 5 --quiet` for candidates. Inspect the source, callers, and tests before choosing one worthwhile, verifiable issue. Prefer reducing needless indirection, consolidating genuinely equivalent code, or simplifying branches; skip candidates that require guessing intended behavior. Run the relevant existing behavioral check on the baseline before editing. If there is no useful check, the check fails, or project policy requires validation you cannot run, report the candidate without editing it.
2. **Refactor.** Capture an unfiltered baseline with `debtmap analyze "$scope" --format json --quiet --output "$before"`. Make the smallest coherent patch. Preserve public contracts, data formats, error behavior, and side-effect order. Leave dependencies, generated files, and analyzer thresholds alone; never remove checks or suppress a finding to improve a score.
3. **Verify.** Re-run the same behavioral check and any applicable focused lint or type check. Review the diff for unrelated edits and run the same JSON scan to `"$after"`. Compare using `debtmap compare --before "$before" --after "$after" --format markdown`. Keep the patch only if checks pass, the target is demonstrably simpler, and the comparison shows no material new debt. A lower score alone is not sufficient. If verification fails, try one narrow correction, then undo only this attempt's own changes and stop. If safe undo is uncertain, stop and identify the unverified edits rather than resetting the tree.
4. **Repeat or stop.** Re-rank after each accepted patch. Stop at the limit, when no safe candidate remains, or when verification or comparison is blocked. Leave accepted patches unstaged; do not commit or push.

Report the scope, accepted changes with file references, what Debtmap reported before and after, exact checks and outcomes, and why the run stopped. Distinguish skipped findings and unverified work from completed cleanup.
