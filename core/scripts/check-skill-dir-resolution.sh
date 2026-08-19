#!/usr/bin/env bash
# Fails if a fenced shell block references ${CLAUDE_SKILL_DIR} anywhere other than
# the canonical resolver assignment.
#
# `${CLAUDE_SKILL_DIR}` expands to a path in the agent loop's filesystem, which the
# shell cannot always reach (on Cowork the agent loop is native to the host while Bash
# runs in a separate VM). Inside a shell block the variable therefore has exactly one
# legitimate appearance -- seeding the resolver:
#
#   SCRIPT=<path>; SKILL_DIR="${CLAUDE_SKILL_DIR}"
#
# Everything downstream must use the resolved "$SKILL_DIR" instead. This is checked as
# an allowlist of one form rather than a denylist of commands, so a new way of reaching
# the path through the shell -- `cat`, shell `grep`, `<` redirection, or executing the
# path directly with no leading command word -- cannot slip past.
#
# Only fenced shell blocks are inspected, because only those are executed. Prose that
# names the forbidden pattern is fine, as are comments inside a block.
#
# See provider-contract SKILL.md, section "Resolving the Skill Directory".
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

python3 - "$@" <<'PY'
import pathlib, re, sys

SHELL_FENCE = re.compile(r'^\s*```(bash|sh|shell|console)\s*$')
FENCE_END   = re.compile(r'^\s*```\s*$')
# The one sanctioned appearance inside a shell block.
CANONICAL   = re.compile(r'^\s*SCRIPT=\S+; SKILL_DIR="\$\{CLAUDE_SKILL_DIR\}"\s*$')
COMMENT     = re.compile(r'^\s*#')

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
        if 'CLAUDE_SKILL_DIR' not in line:
            continue
        if CANONICAL.match(line) or COMMENT.match(line):
            continue
        violations.append((path, n, line.strip()))

if violations:
    print("Unresolved ${CLAUDE_SKILL_DIR} use in shell blocks "
          "(%d violation(s)):\n" % len(violations))
    for path, n, line in violations:
        print("  %s:%d\n    %s" % (path, n, line))
    print("\nInside a shell block, ${CLAUDE_SKILL_DIR} may appear only as:")
    print('    SCRIPT=<path>; SKILL_DIR="${CLAUDE_SKILL_DIR}"')
    print('Use the resolved "$SKILL_DIR" everywhere else, and resolve in the SAME')
    print("shell invocation as the use. Canonical resolver:")
    print("  core/skills/provider-contract/SKILL.md")
    print('  section "Resolving the Skill Directory"')
    sys.exit(1)

print("OK: ${CLAUDE_SKILL_DIR} appears only in canonical resolver assignments.")
PY
