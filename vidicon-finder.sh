#!/bin/zsh
# vidicon-finder: Set video icons in current Finder folder
# Each Cmd+R cycles: 5% → 25% → 50% → 75% → 5%

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

# Cycle position
CF=~/.vidicon_pos
[ ! -f "$CF" ] && echo "0" > "$CF"
POS=$(cat "$CF")
SEEKS=(5 25 50 75)
S=${SEEKS[$((POS % 4 + 1))]}
echo $(( (POS + 1) % 4 )) > "$CF"

osascript -e "display notification \"Setting icons at ${S}%...\" with title \"VidIcon\""
/usr/local/bin/vidicon icons "$FOLDER" --seek "$S" 2>/dev/null
osascript -e "display notification \"Done! (${S}%) Next press: ${SEEKS[$(( (POS + 1) % 4 + 1 ))]}%\" with title \"VidIcon ✅\" sound name \"Glass\""
