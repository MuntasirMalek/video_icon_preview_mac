#!/bin/zsh
# vidicon-finder: Set video icons from Finder
# - If files are selected: sets icons for selected videos only
# - If no files selected: sets icons for entire folder
# Each Cmd+R cycles: 5% → 10% → 15% → ... → 95% → 5%

VIDICON=/usr/local/bin/vidicon
if [[ ! -x "$VIDICON" ]]; then
  osascript -e 'display notification "vidicon not found at /usr/local/bin/vidicon" with title "VidIcon ❌" sound name "Basso"'
  exit 1
fi

# Cycle position: 5% → 10% → 15% → ... → 95% → 5%
CF=~/.vidicon_pos
[ ! -f "$CF" ] && echo "0" > "$CF"
POS=$(cat "$CF")
SEEKS=(50 60 70 80 90 10 20 30 40)
S=${SEEKS[$((POS % 9 + 1))]}
echo $(( (POS + 1) % 9 )) > "$CF"
NEXT_S=${SEEKS[$(( (POS + 1) % 9 + 1 ))]}

# Check if specific files are selected in Finder
SELECTED=$(osascript <<'AS'
tell application "Finder"
  set sel to selection
  if (count of sel) > 0 then
    set paths to {}
    repeat with f in sel
      set end of paths to POSIX path of (f as alias)
    end repeat
    set AppleScript's text item delimiters to "
"
    return paths as text
  else
    return ""
  end if
end tell
AS
)

if [[ -n "$SELECTED" ]]; then
  # Selected files mode
  COUNT=$(echo "$SELECTED" | wc -l | tr -d ' ')
  osascript -e "display notification \"Setting icons for ${COUNT} file(s) at ${S}%...\" with title \"VidIcon\""
  FAIL=0
  while IFS= read -r FILE; do
    "$VIDICON" icon "$FILE" --seek "$S" 2>/dev/null || FAIL=$((FAIL + 1))
  done <<< "$SELECTED"
  if [[ $FAIL -eq 0 ]]; then
    osascript -e "display notification \"Done! ${COUNT} file(s) at ${S}%. Next: ${NEXT_S}%\" with title \"VidIcon ✅\" sound name \"Glass\""
  else
    osascript -e "display notification \"Done with ${FAIL} error(s). Next: ${NEXT_S}%\" with title \"VidIcon ⚠️\" sound name \"Glass\""
  fi
else
  # Folder mode
  FOLDER=$(osascript <<'AS'
tell application "Finder"
  if (count of Finder windows) > 0 then
    return POSIX path of (target of front Finder window as alias)
  else
    return POSIX path of (desktop as alias)
  end if
end tell
AS
  )
  [ -z "$FOLDER" ] && exit 1

  osascript -e "display notification \"Setting icons at ${S}%...\" with title \"VidIcon\""

  if "$VIDICON" icons "$FOLDER" --seek "$S" 2>/dev/null; then
    osascript -e "display notification \"Done! (${S}%) Next: ${NEXT_S}%\" with title \"VidIcon ✅\" sound name \"Glass\""
  else
    osascript -e "display notification \"Failed to set icons\" with title \"VidIcon ❌\" sound name \"Basso\""
  fi
fi
