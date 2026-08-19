#!/usr/bin/env bash
# Fails if any fenced shell block invokes a bundled file through ${CLAUDE_SKILL_DIR}
# without first resolving it. See provider-contract § Resolving the Skill Directory.
#
# Prose that merely *names* the forbidden pattern is fine — only fenced shell blocks
# are inspected, because only those are executed.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

python3 - "$@" <<'PY'
import pathlib, re, sys

SHELL_FENCE = re.compile(r'^\s*```(bash|sh|shell|console)\s*$')
FENCE_END   = re.compile(r'^\s*```\s*$')
# A shell command reaching a bundled file through the unresolved variable.
BAD = re.compile(r'(^|[|&;(]|\$\()\s*'
                 r'(bash|sh|source|\.|cd|exec|npm|npx|node|python3?)\s+'
                 r'[^#\n]*\$\{CLAUDE_SKILL_DIR\}')
# The only sanctioned appearance inside a shell block.
OK = re.compile(r'^\s*SCRIPT=\S+; SKILL_DIR="\$\{CLAUDE_SKILL_DIR\}"\s*$')

violations = []
for path in sorted(pathlib.Path('.').rglob('*.md')):
    if any(p in ('.git', 'node_modules', '.claude') for p in path.parts):
        continue
    if path.name == 'CHANGELOG.md':
        continue
    in_shell = False
    for n, line in enumerate(path.read_text().split('\n'), 1):
        if not in_shell:
            if SHELL_FENCE.match(line):
                in_shell = True
            continue
        if FENCE_END.match(line):
            in_shell = False
            continue
        if '${CLAUDE_SKILL_DIR}' not in line or OK.match(line):
            continue
        if BAD.search(line):
            violations.append((path, n, line.strip()))

if violations:
    print("Unresolved ${CLAUDE_SKILL_DIR} use in shell blocks "
          "(%d violation(s)):\n" % len(violations))
    for path, n, line in violations:
        print("  %s:%d\n    %s" % (path, n, line))
    print("\nResolve the skill directory in the SAME shell invocation before use.")
    print("Canonical resolver: core/skills/provider-contract/SKILL.md")
    print("  § Resolving the Skill Directory")
    sys.exit(1)

print("OK: no unresolved ${CLAUDE_SKILL_DIR} shell invocations found.")
PY
