---
name: cli-tools
description: Reference docs for token-optimized CLI tools - qmd, ast-grep, semgrep, fastmod, and RTK. Load before first use of any code search/rewrite tool or RTK meta commands.
tools: Bash
---

# CLI Tools Reference

Token-optimized CLI tools for code search, structural rewriting, and analytics.

## Tool Selection Decision Tree

1. **Need to read specific lines?** → `qmd get` (find line first with `rg -n`)
2. **Renaming a method call or expression?** → `ast-grep`
3. **Structural pattern with varying arguments?** → `semgrep`
4. **Literal string replacement (config keys, identifiers)?** → `fastmod`
5. **Token savings analytics?** → `rtk gain` / `rtk discover`

If the target is not a syntax expression (YAML keys, plain strings, config values), skip ast-grep/semgrep and use fastmod.

---

## qmd

Retrieve an exact passage from a source file by line range (99.2% token reduction).

```bash
qmd get <file>:<line> -l <count>   # read N lines starting at line
qmd get src/main/App.java:120 -l 30
```

**Workflow**: Always find the line number first with `rg -n <pattern> <file>`, then `qmd get`. Never read a whole file when you only need one function.

---

## ast-grep

AST-aware search and structural rewrite (93.3% token reduction).

```bash
ast-grep run --pattern '<pattern>' --lang <lang> .          # search
ast-grep run --pattern '<old>' --rewrite '<new>' --lang <lang> -U .  # rewrite
```

**When to use:**

- Renaming a method, function call, or expression across a codebase
- When fastmod would match inside comments or strings (wrong)
- Supported languages: Java, TypeScript, JavaScript, Python, Go, Rust, C, C++

**When NOT to use:**

- Bare identifiers across config files, YAML, or plain strings → use fastmod
- The pattern is not a valid syntax fragment in the target language

---

## semgrep

Lightweight static analysis and structural rewriting.

```bash
semgrep scan --pattern '<pattern>' --lang <lang> .              # search
semgrep scan --pattern '<pattern>' --lang <lang> --json .       # machine-readable
semgrep scan --config <rule.yaml> .                             # run a rule file
```

**When to use:**

- Structural patterns where arguments or expressions vary
- Enforcing or detecting code patterns across a codebase
- Too complex for fastmod but ast-grep's exact AST is too rigid
- Use metavariables (`$X`, `$FUNC`, `$...ARGS`) to match arbitrary expressions

**When NOT to use:**

- Simple literal string rename → fastmod
- Specific method call with no argument variation → ast-grep
- Languages not supported by semgrep → fastmod

---

## fastmod

Fast literal string replacement across a codebase (65.1% token reduction).

```bash
fastmod --accept-all --fixed-strings <old> <new> -e <ext> .
fastmod --accept-all --fixed-strings old_name new_name -e java,yaml .
```

**When to use:**

- Renaming a config key, underscore identifier, or any literal string across many files
- The text to replace is not a syntax expression (no method calls, no parentheses)
- Use `--fixed-strings` to disable regex interpretation; `-e` to restrict by extension

**When NOT to use:**

- Method call or expression → ast-grep
- Structural variation (different argument shapes) → semgrep

---

## RTK - Rust Token Killer

Token-optimized CLI proxy (60-90% savings on dev operations). Most commands are transparently rewritten by the Claude Code hook — these are the meta commands you invoke directly:

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
```
