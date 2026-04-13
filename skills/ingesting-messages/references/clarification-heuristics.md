# Clarification Heuristics (LLM-driven)

This reference is read by the LLM during Step 2.3 of the ingesting-messages skill. It explains how to decide whether an ambiguous Category A message can be resolved by sending a short clarification reply to the sender in the same Slack thread, and how to compose that reply.

The heuristics here are deliberately LLM-driven (not regex-driven). Earlier drafts proposed regex-based detection with verb lists, negation tokens, and pattern matches — but they fall apart on real-world messages:

- "This is **not** urgent" matches `urgent` under a naïve regex yet means the opposite
- "Fix the thing" has a verb but a vague target — a regex cannot tell that the target is vague
- "商品ページの見た目を綺麗にして" has action (綺麗にする) and target (商品ページ) yet leaves completion undefined — this is exactly the semantic judgment the LLM is good at

Use the LLM's native multilingual understanding directly. The three dimensions below are a mental checklist, not a regex schema.

## The three dimensions

For each Category A message, reason about whether each dimension is sufficiently clear.

### 1. Action (what to do)

**Clear** — the message contains a specific action verb that tells you what kind of work is requested:
- fix, update, review, deploy, document, create, delete, refactor, investigate
- 修正する、更新する、レビューする、デプロイする、ドキュメント化する、作成する、削除する、調査する

**Ambiguous** — generic verbs that signal intent but not the action type:
- "take a look", "handle it", "deal with this", "check on this"
- 「見てほしい」「対応して」「確認して」(in isolation — these may be clear with enough context)

**Examples**:
- "Please fix the login bug" → clear (action = fix)
- "Can you look at this?" → ambiguous (look how? diagnose? review? rewrite?)
- "これ対応してもらえる？" → ambiguous (対応 is too vague without context)

### 2. Target (what to act on)

**Clear** — the message names a concrete target the LLM can identify:
- A file path, repo name, URL, issue number, PR number, well-known entity
- "Update `src/auth/login.ts`"
- "anuansの商品ページ" (a named store + concrete page)

**Ambiguous** — references the LLM cannot resolve:
- "the thing", "that issue", "our site" without surrounding context
- "昨日話してたやつ" / "例のページ"

**Examples**:
- "Update `src/auth/login.ts`" → clear (specific file)
- "Fix the thing we talked about yesterday" → ambiguous (what thing?)
- "商品ページの表示がおかしい" → partially clear (商品ページ but which store?)

### 3. Completion condition (what "done" looks like)

**Clear** — the message describes an observable outcome:
- Numeric threshold ("under 2s", "returns 200", "3 items per row")
- State verb ("the page displays", "the test passes", "the API returns")
- Explicit matches ("matches the design mockup", "same as the other store")

**Ambiguous** — vague success criteria:
- "it should work", "looks good", "is fixed", "nicely"
- 「ちゃんと動くように」「いい感じに」

**Examples**:
- "the page should load in under 2 seconds" → clear (numeric threshold)
- "make it better" → ambiguous (better by what measure?)
- "ちゃんと動くように" → ambiguous (ちゃんと is vague)

## Decision rule

Count how many dimensions are ambiguous, then:

| Ambiguous dimensions | Recommended action |
|---|---|
| 0 (all three clear) | Reclassify this message as Category B — it is not actually ambiguous |
| 1 | Send 1 clarification question targeting the ambiguous dimension |
| 2 | Send 2 clarification questions (targeting both ambiguous dimensions) |
| 3 | Present user choice: send 3 clarification questions, OR create a `[Hearing]` task pair, OR skip. Three dimensions of ambiguity usually means the sender needs a live conversation, not a checklist — a hearing task is often the right call. |

## Question templates

The LLM composes the final reply in the sender's language (detected via the LLM's native language understanding — no char-class regex). Start from these templates and adapt them to the specific context of the message so the reply does not feel robotic.

**Action unclear**:
- en: "What specific action should I take on this?"
- ja: "具体的には何をすればよいでしょうか？"

**Target unclear**:
- en: "Which file / page / component should I modify?"
- ja: "どのファイル・ページ・コンポーネントを対象にすればよいでしょうか？"

**Completion unclear**:
- en: "What does 'done' look like — what's the expected outcome?"
- ja: "完了の条件は何でしょうか？期待する結果を教えてください。"

## Composing the full reply

Wrap the questions in a short, friendly framing. Keep it short — the goal is to make it easy for the sender to answer. Do NOT paste the full waggle jargon.

Template (English):

```
👋 Thanks for the message! Before I pick this up, could you clarify:
- {question 1}
- {question 2}
```

Template (Japanese):

```
👋 ありがとうございます！作業に取り掛かる前に、以下を教えてください：
- {question 1}
- {question 2}
```

If only one question is needed, drop the list format and write it inline.

## What to do when clarification is not viable

Fall through to the existing `[Hearing]` task creation (defined in `task-creation-templates.md`) when any of the following is true:

- The current run is not explicitly interactive (`WAGGLE_EXECUTION_MODE` is unset or set to `scheduled`)
- The messaging MCP is not Slack (Teams/Discord clarification is not implemented yet)
- The sender is a bot or system account
- A clarification was already sent to this thread within the last 24 hours (idempotency)
- The Slack send itself fails (network, permission, rate limit)

Step 2.3e in `SKILL.md` defines the full fallback chain.
