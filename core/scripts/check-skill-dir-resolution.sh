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
import pathlib, re, subprocess, sys


def target_files():
    """Markdown files git tracks, or every .md file when git is unavailable.

    Scoping to tracked files matters for local runs: a contributor may keep
    untracked or locally-excluded notes in the tree -- a design document quoting an
    abbreviated resolver, for instance -- which CI never sees because it clones. A
    naive walk fails on those and makes the check useless as a local pre-commit
    step, which is the moment it is most valuable.
    """
    try:
        out = subprocess.run(['git', 'ls-files', '-z', '--', '*.md'],
                             capture_output=True, text=True, check=True).stdout
        return sorted(pathlib.Path(n) for n in out.split('\0') if n)
    except (OSError, subprocess.CalledProcessError):
        return sorted(pathlib.Path('.').rglob('*.md'))

SHELL_FENCE = re.compile(r'^\s*```(bash|sh|shell|console)\s*$')
FENCE_END   = re.compile(r'^\s*```\s*$')
CANONICAL   = re.compile(r'^\s*SCRIPT=(\S+); SKILL_DIR="\$\{CLAUDE_SKILL_DIR\}"\s*$')
COMMENT     = re.compile(r'^\s*#')
USES_SD     = re.compile(r'\$\{?SKILL_DIR\b')
FAIL_OPEN   = '# waggle-ci: fail-open'


def strip_comment(line):
    """Drop a trailing shell comment, leaving the code.

    A bare `#` split is wrong here: the resolver itself contains `#` inside
    `${SKILL_DIR#*/plugin_}`, which is the clause most worth checking. A comment `#`
    is one that starts a word -- at line start or after whitespace -- while outside
    quotes and outside `${...}`. Track those three states and cut at the first such
    `#`, so a fragment hidden in a trailing comment cannot pass for real code.
    """
    sq = dq = False
    depth = 0
    prev = ' '
    for i, c in enumerate(line):
        if sq:
            if c == "'":
                sq = False
        elif dq:
            if c == '\\':
                prev = c
                continue
            if c == '"':
                dq = False
            elif c == '{' and prev == '$':
                depth += 1
            elif c == '}' and depth:
                depth -= 1
        elif c == "'":
            sq = True
        elif c == '"':
            dq = True
        elif c == '{' and prev == '$':
            depth += 1
        elif c == '}' and depth:
            depth -= 1
        elif c == '#' and depth == 0 and (prev.isspace() or i == 0):
            return line[:i]
        prev = c
    return line

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

for path in target_files():
    if any(p in ('.git', 'node_modules', '.claude') for p in path.parts):
        continue
    if path.name == 'CHANGELOG.md':
        continue
    if not path.is_file():
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
        # Comments must not satisfy the completeness or guard checks: a block that
        # deletes the resolver but describes it in a comment is still gutted.
        code = '\n'.join(strip_comment(l) for _, l in block if not COMMENT.match(l))
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
            if frag not in code:
                flag(path, first_assign,
                     'resolver is incomplete -- missing %s' % label, frag)

        # FAIL_OPEN is itself a comment, so it is matched against the full body.
        if FAIL_OPEN in body:
            continue

        guard_lines = [n for n, l in block
                       if not COMMENT.match(l) and GUARD in strip_comment(l)]
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
            if CANONICAL.match(l) or COMMENT.match(l):
                continue
            l = strip_comment(l)
            if n >= guard or not USES_SD.search(l):
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
