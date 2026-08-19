#!/usr/bin/env bash
# Enforces the skill-directory resolution contract in fenced shell blocks.
#
# `${CLAUDE_SKILL_DIR}` expands to a path in the agent loop's filesystem, which the
# shell cannot always reach (on Cowork the agent loop is native to the host while Bash
# runs in a separate VM). See provider-contract SKILL.md, section "Resolving the Skill
# Directory", for the canonical resolver and why each of its clauses is required.
#
# Three properties are checked per fenced shell block. Each Bash call is a fresh
# process, so the *block* is the unit -- a resolver in an earlier block does not carry
# over, which is precisely the failure this guard exists to catch.
#
#   1. NO UNRESOLVED USE. `${CLAUDE_SKILL_DIR}` may appear only as
#        SCRIPT=<path>; SKILL_DIR="${CLAUDE_SKILL_DIR}"
#      This is an allowlist of one form, not a denylist of commands: a denylist would
#      have to enumerate every way a path reaches the shell (`bash`, `cd`, `source`,
#      `cat`, shell `grep`, `<` redirection, `awk -f`, `PATH` injection, or executing
#      the path with no leading command word) and would pass whichever it forgot.
#
#   2. SELF-CONTAINED. A block that uses "$SKILL_DIR" must itself assign it. Catches a
#      recipe relying on a resolver placed once at the top of a document section.
#
#   3. COMPLETE AND FAIL-CLOSED. A block that assigns it must carry the whole resolver
#      body -- both tiers -- and a fail-closed guard before use. Catches a block that
#      keeps the assignment but drops the conversion, the scoped search, or the guard,
#      which would silently resolve to a wrong or unchecked path.
#
# A site that must fail OPEN instead (a best-effort convenience step, never a check or
# a write) declares itself with a `# waggle-ci: fail-open` comment inside the block.
#
# Only fenced shell blocks are inspected, because only those are executed. Prose naming
# a forbidden pattern is fine, as are comments inside a block.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

python3 - "$@" <<'PY'
import pathlib, re, sys

SHELL_FENCE = re.compile(r'^\s*```(bash|sh|shell|console)\s*$')
FENCE_END   = re.compile(r'^\s*```\s*$')
CANONICAL   = re.compile(r'^\s*SCRIPT=(\S+); SKILL_DIR="\$\{CLAUDE_SKILL_DIR\}"\s*$')
COMMENT     = re.compile(r'^\s*#')
USES_SD     = re.compile(r'\$\{?SKILL_DIR\b')
FAIL_OPEN   = '# waggle-ci: fail-open'

# Signature fragments of the canonical resolver body. Substring matches, so cosmetic
# reflowing is tolerated but omitting a clause is not.
REQUIRED = [
    ('tier-1 runtime discriminator',   '[ ! -d "$SKILL_DIR" ]'),
    ('tier-1 session root',            '${PWD%%/mnt/*}'),
    ('tier-1 plugin_ guard',           '*/plugin_*)'),
    ('tier-1 shortest-match cut',      '${SKILL_DIR#*/plugin_}'),
    ('tier-1 mount root',              '.remote-plugins'),
    ('tier-2 scoped search',           'find "'),
    ('tier-2 single-candidate check',  'grep -c .'),
]
GUARD = '[ -f "$SKILL_DIR/$SCRIPT" ] ||'

problems = []
def flag(path, line, msg, detail=''):
    problems.append((path, line, msg, detail))

for path in sorted(pathlib.Path('.').rglob('*.md')):
    if any(p in ('.git', 'node_modules', '.claude') for p in path.parts):
        continue
    if path.name == 'CHANGELOG.md':
        continue

    lines = path.read_text().split('\n')
    in_shell = False
    block, start = [], 0
    for n, line in enumerate(lines + [None], 1):
        if line is None:
            break
        if not in_shell:
            if SHELL_FENCE.match(line):
                in_shell, block, start = True, [], n
            continue
        if not FENCE_END.match(line):
            block.append((n, line))
            continue
        in_shell = False

        body = '\n'.join(l for _, l in block)
        assigns = [(n, m) for n, l in block for m in [CANONICAL.match(l)] if m]

        # (1) no unresolved use
        for n, l in block:
            if 'CLAUDE_SKILL_DIR' not in l or COMMENT.match(l) or CANONICAL.match(l):
                continue
            flag(path, n, 'unresolved ${CLAUDE_SKILL_DIR} in a shell block', l.strip())

        uses = [n for n, l in block
                if USES_SD.search(l) and not CANONICAL.match(l) and not COMMENT.match(l)]

        # (2) self-contained
        if uses and not assigns:
            flag(path, uses[0],
                 'uses "$SKILL_DIR" but this block never resolves it '
                 '(a resolver in an earlier block does not carry over)')
            continue
        if not assigns:
            continue

        first_assign = assigns[0][0]
        if uses and min(uses) < first_assign:
            flag(path, min(uses), 'uses "$SKILL_DIR" before the resolver assigns it')

        # (3) complete and fail-closed
        for label, frag in REQUIRED:
            if frag not in body:
                flag(path, first_assign,
                     'resolver is incomplete -- missing %s' % label, frag)

        if FAIL_OPEN in body:
            continue

        guard_lines = [n for n, l in block if GUARD in l]
        if not guard_lines:
            flag(path, first_assign,
                 'no fail-closed guard (expected %s), and the block does not declare '
                 '"%s"' % (GUARD, FAIL_OPEN))
            continue

        # The guard must precede the real use. Uses inside the resolver body itself
        # (its own tests on $SKILL_DIR) are not "use" -- identify them by the clause
        # signatures, so only the invocation is subject to the ordering rule.
        guard = guard_lines[0]
        resolver_frags = [frag for _, frag in REQUIRED] + [GUARD]
        for n, l in block:
            if n >= guard or not USES_SD.search(l):
                continue
            if CANONICAL.match(l) or COMMENT.match(l):
                continue
            if any(frag in l for frag in resolver_frags):
                continue
            flag(path, n,
                 'uses "$SKILL_DIR" at line %d, before the fail-closed guard at line '
                 '%d -- the operation could run against an unchecked path' % (n, guard))

if problems:
    print("Skill-directory resolution contract violated (%d problem(s)):\n"
          % len(problems))
    for path, n, msg, detail in problems:
        print("  %s:%d\n    %s" % (path, n, msg))
        if detail:
            print("      %s" % detail)
    print('\nInside a shell block, ${CLAUDE_SKILL_DIR} may appear only as:')
    print('    SCRIPT=<path>; SKILL_DIR="${CLAUDE_SKILL_DIR}"')
    print('followed by the full resolver body and a fail-closed guard, in the SAME')
    print('block as the use. Canonical resolver:')
    print('  core/skills/provider-contract/SKILL.md')
    print('  section "Resolving the Skill Directory"')
    sys.exit(1)

print("OK: every shell block that touches the skill directory resolves it "
      "completely, in-block, and fails closed.")
PY
