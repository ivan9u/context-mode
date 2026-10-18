#!/usr/bin/env bash
# Install context-mode skills (and the MCP server they depend on) at user scope,
# so every project and every agent on this machine can use them by default.
#
#   Skills  -> ~/.cursor/skills, ~/.claude/skills, ~/.agents/skills, ~/.codex/skills
#   MCP     -> ~/.cursor/mcp.json, ~/.claude.json, ~/.codex/config.toml
#
# Usage: scripts/install-global-skills.sh [--link] [--skills-only] [--uninstall]
#   --link         symlink skill directories to this checkout instead of copying
#   --skills-only  do not touch MCP config files
#   --uninstall    remove previously installed skills and MCP entries
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/skills"
SKILL_TARGETS=(
  "$HOME/.cursor/skills"
  "$HOME/.claude/skills"
  "$HOME/.agents/skills"
  "$HOME/.codex/skills"
)

MODE=copy
DO_MCP=1
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --link) MODE=link ;;
    --skills-only) DO_MCP=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ -d "$SRC_DIR" ] || { echo "skills/ not found at $SRC_DIR" >&2; exit 1; }

skills=()
for d in "$SRC_DIR"/*/; do
  [ -f "$d/SKILL.md" ] && skills+=("$(basename "$d")")
done

for target in "${SKILL_TARGETS[@]}"; do
  mkdir -p "$target"
  for name in "${skills[@]}"; do
    dest="$target/$name"
    rm -rf "$dest"
    [ "$UNINSTALL" = 1 ] && continue
    if [ "$MODE" = link ]; then
      ln -s "$SRC_DIR/$name" "$dest"
    else
      cp -R "$SRC_DIR/$name" "$dest"
    fi
  done
  if [ "$UNINSTALL" = 1 ]; then
    echo "removed ${#skills[@]} skills from $target"
  else
    echo "installed ${#skills[@]} skills -> $target ($MODE)"
  fi
done

[ "$DO_MCP" = 1 ] || exit 0

if ! command -v node >/dev/null 2>&1; then
  echo "node not found; skipped MCP registration (skills installed)" >&2
  exit 0
fi

UNINSTALL="$UNINSTALL" node --input-type=module - <<'NODE'
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const home = os.homedir();
const uninstall = process.env.UNINSTALL === "1";
const server = { command: "npx", args: ["-y", "context-mode"] };

function updateJson(file, mutate) {
  let data = {};
  if (fs.existsSync(file)) {
    const raw = fs.readFileSync(file, "utf8").trim();
    if (raw) {
      try {
        data = JSON.parse(raw);
      } catch {
        console.error(`skip ${file}: not valid JSON`);
        return;
      }
    }
  } else if (uninstall) {
    return;
  }
  mutate(data);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  console.log(`${uninstall ? "unregistered" : "registered"} context-mode MCP -> ${file}`);
}

for (const file of [path.join(home, ".cursor/mcp.json"), path.join(home, ".claude.json")]) {
  updateJson(file, (data) => {
    data.mcpServers ??= {};
    if (uninstall) delete data.mcpServers["context-mode"];
    else data.mcpServers["context-mode"] ??= server;
  });
}

const toml = path.join(home, ".codex/config.toml");
const header = "[mcp_servers.context-mode]";
const block = `${header}\ncommand = "npx"\nargs = ["-y", "context-mode"]\n`;
const existing = fs.existsSync(toml) ? fs.readFileSync(toml, "utf8") : "";
if (uninstall) {
  if (existing.includes(header)) {
    fs.writeFileSync(toml, existing.replace(/\n*^\[mcp_servers\.context-mode\]\n(?:(?!\[)[^\n]*\n?)*/m, "\n"));
    console.log(`unregistered context-mode MCP -> ${toml}`);
  }
} else if (!existing.includes(header)) {
  fs.mkdirSync(path.dirname(toml), { recursive: true });
  fs.writeFileSync(toml, existing + (existing && !existing.endsWith("\n") ? "\n" : "") + (existing ? "\n" : "") + block);
  console.log(`registered context-mode MCP -> ${toml}`);
}
NODE
