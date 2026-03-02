#!/bin/zsh

# Get current Finder folder BEFORE doing anything
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

# Cycle: 5 → 25 → 50 → 75 → 5
CF=~/.vidicon_pos
[ ! -f "$CF" ] && echo "0" > "$CF"
POS=$(cat "$CF")
SEEKS=(5 25 50 75)
S=${SEEKS[$((POS % 4 + 1))]}
echo $(( (POS + 1) % 4 )) > "$CF"

# Set the icons
/usr/local/bin/vidicon icons "$FOLDER" --seek "$S" 2>/dev/null

# Restart Finder and reopen the SAME folder
killall Finder 2>/dev/null
sleep 1
open "$FOLDER"

osascript -e "display notification \"Done! Icons at ${S}%\" with title \"VidIcon ✅\" sound name \"Glass\""
