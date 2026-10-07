#!/bin/sh
# Claude Code status line: context fill, model, and the spend of the session's customer
# (today and all time, or since the day chosen in the app) as computed by the trackme app on
# the first line; the folder and git branch, with a tick for a clean tree, on the second.
#
#   ./statusline.sh install    point Claude Code's statusLine setting at this script
#   ./statusline.sh remove     take it out again
#
# Claude Code runs the script after every assistant message and pipes a JSON document to
# stdin (https://code.claude.com/docs/en/statusline). The spend comes from
# ~/Library/Application Support/trackme/status.json, which the trackme app rewrites after
# every scan, so this script never reads a transcript itself. Needs jq (part of macOS 15+).

STATUS="$HOME/Library/Application Support/trackme/status.json"

settings_path() {
    dir=$(printf '%s' "${CLAUDE_CONFIG_DIR:-}" | cut -d, -f1 | sed 's/^ *//;s/ *$//')
    [ -n "$dir" ] || dir="$HOME/.claude"
    case "$dir" in "~"*) dir="$HOME${dir#\~}" ;; esac
    printf '%s/settings.json' "$dir"
}

self_path() {
    cd "$(dirname "$0")" && printf '%s/%s' "$(pwd -P)" "$(basename "$0")"
}

case "$1" in
install|remove)
    file=$(settings_path)
    mkdir -p "$(dirname "$file")"
    [ -s "$file" ] || printf '{}\n' > "$file"
    [ -e "$file.before-trackme" ] || cp "$file" "$file.before-trackme"
    if [ "$1" = install ]; then
        me=$(self_path)
        jq --arg cmd "\"$me\"" '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' \
            "$file" > "$file.tmp" && mv "$file.tmp" "$file" && echo "Status line installed in $file"
        echo "Sessions already running pick it up when restarted."
    else
        jq 'if (.statusLine.command // "" | test("statusline\\.sh")) then del(.statusLine) else . end' \
            "$file" > "$file.tmp" && mv "$file.tmp" "$file" && echo "Status line removed from $file"
    fi
    exit 0
    ;;
esac

input=$(cat)
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
branch=""
dirty=""
if [ -n "$dir" ]; then
    branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null \
          || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    [ -n "$branch" ] && [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -n 1)" ] && dirty=1
fi
[ -r "$STATUS" ] && status="$STATUS" || status=/dev/null

printf '%s' "$input" | jq -r --slurpfile st "$status" --arg branch "$branch" --arg dirty "$dirty" --arg home "$HOME" --argjson now "$(date +%s)" '
    def dim: "\u001b[2m" + . + "\u001b[0m";
    def bold: "\u001b[1m" + . + "\u001b[0m";
    def paint($c): "\u001b[" + $c + "m" + . + "\u001b[0m";
    def k: if . >= 1000000 then ((. / 100000 | round) / 10 | tostring | sub("\\.0$"; "")) + "M"
           elif . >= 1000 then ((. / 1000) | round | tostring) + "K"
           else tostring end;
    def money: (. * 100 | round) as $c
        | if $c >= 100000 then "$" + ($c / 100 | round | tostring)
          else "$" + ($c / 100 | floor | tostring) + "." + ($c % 100 | tostring | if length < 2 then "0" + . else . end)
          end;

    # Context: Claude Code gives the fill as a percentage of the window; both can be null early on.
    (.context_window // {}) as $cw
    | ($cw.used_percentage) as $pct
    | ($cw.current_usage // {} | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))) as $used
    | (if $pct == null then "–%" | dim
       else (($pct | round | tostring) + "%"
             | paint(if $pct < 50 then "32" elif $pct < 80 then "33" else "31" end))
            + (if $cw.context_window_size then " " + (($used | k) + "/" + ($cw.context_window_size | k) | dim) else "" end)
       end) as $context

    | (.model.display_name // .model.id // "?" | bold) as $model

    # Folder and branch, on their own line: ~/path/to/folder (branch ✔), the tick turning into a
    # red cross when the tree has uncommitted changes.
    | ((.workspace.current_dir // .cwd // "") | if . == $home then "~" elif startswith($home + "/") then "~" + .[($home | length):] else . end | paint("36")) as $folder
    | (if $branch == "" then ""
       else " (" + ($branch | paint("35")) + " " + (if $dirty == "" then ("✔" | paint("32")) else ("✗" | paint("31")) end) + ")"
       end) as $git

    # Spend: the customer of this session, from the app; the session name is a fallback for a
    # session the app has not scanned yet.
    | ($st[0]) as $s
    | (.session_id // "") as $sid
    | ((.session_name // "") | split(":") | .[0] // "" | sub("^\\s+"; "") | sub("\\s+$"; "")) as $nameTag
    | (if $s then ($s.sessions[$sid] // (if $nameTag == "" then "Other" else $nameTag end)) else null end) as $customer
    | (if $s == null then
           ((.cost.total_cost_usd // 0 | money) + " this session" | dim) + " " + ("trackme not running" | paint("31"))
       else
           ($s.customers[$customer] // {today: 0, total: 0}) as $sp
           | ($customer | bold) + " " + ($sp.today | money) + (" today" | dim) + " · " + ($sp.total | money)
             + (" " + (if $s.since then "since " + $s.since else "total" end) | dim)
             + (if ($now - ($s.generatedAt // 0)) > 120 then " " + ("stale" | paint("31")) else "" end)
       end) as $spend

    | ([$context, $model, $spend] | join(" │ " | dim)) + "\n" + $folder + $git
'
