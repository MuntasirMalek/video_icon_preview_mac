#!/bin/zsh

# Get current Finder folder
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

# Simple global counter for cycling 5 → 25 → 50 → 75 → 5
CF=~/.vidicon_pos
[ ! -f "$CF" ] && echo "0" > "$CF"
POS=$(cat "$CF")
SEEKS=(5 25 50 75)
S=${SEEKS[$((POS % 4 + 1))]}
echo $(( (POS + 1) % 4 )) > "$CF"

osascript -e "display notification \"Setting icons at ${S}%\" with title \"VidIcon\""
/usr/local/bin/vidicon icons "$FOLDER" --seek "$S" 2>/dev/null

# Refresh Finder window without killing it
osascript <<'AS2'
tell application "Finder"
  if (count of Finder windows) > 0 then
    set theTarget to target of front Finder window
    set target of front Finder window to theTarget
  end if
end tell
AS2

osascript -e "display notification \"Done! (${S}%)\" with title \"VidIcon ✅\" sound name \"Glass\""
