# Waggle — Turso Provider Setup

## Step 1: Prerequisites

Verify required tools:

```bash
command -v curl && echo "curl: OK" || echo "curl: NOT FOUND"
command -v jq && echo "jq: OK" || echo "jq: NOT FOUND"
```

## Step 2: Turso Account

Ask the user:
> "Do you already have a Turso database URL and auth token? If not, you can create one at https://turso.tech (free tier available)."

If the user needs help:
1. Sign up at https://turso.tech
2. Install Turso CLI: `curl -sSfL https://get.tur.so/install.sh | bash`
3. Login: `turso auth login`
4. Create database: `turso db create waggle`
5. Get URL: `turso db show waggle --url`
6. Create token: `turso db tokens create waggle`

## Step 3: Configure

Get the URL and token from the user via AskUserQuestion:
> "Please provide your Turso database URL (e.g. https://waggle-username.turso.io):"

Then:
> "Please provide your Turso auth token:"

Write config:
```bash
mkdir -p ~/.waggle
cat > ~/.waggle/config.json << EOF
{
  "provider": "turso",
  "tursoUrl": "<user_provided_url>",
  "tursoAuthToken": "<user_provided_token>"
}
EOF
```

Also set env vars in `~/.claude/settings.json` for script access:
```json
{
  "env": {
    "TURSO_URL": "<user_provided_url>",
    "TURSO_AUTH_TOKEN": "<user_provided_token>"
  }
}
```

## Step 4: Initialize Database

```bash
export TURSO_URL="<url>"
export TURSO_AUTH_TOKEN="<token>"
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/init-db.sh
```

## Step 5: Verify

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "INSERT INTO tasks (title, status, priority) VALUES ('Setup test', 'Backlog', 'Low') RETURNING id, title, status;" \
  "DELETE FROM tasks WHERE title = 'Setup test';"
```

If successful, report:
> "Turso provider is set up. Database at `<turso_url>`. Ready to use."
