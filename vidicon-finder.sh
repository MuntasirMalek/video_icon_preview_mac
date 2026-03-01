#!/bin/bash
# vidicon-finder: Get current Finder folder and set video icons
# Each press cycles: 5% → 25% → 50% → 75% → 5%

STATE_DIR="$HOME/.config/vidicon"

# Cycle positions
POSITIONS=(5 25 50 75)

# Get current Finder folder
FOLDER=$(osascript -e '
tell application "Finder"
    if (count of Finder windows) > 0 then
        set theFolder to (target of front Finder window) as alias
        return POSIX path of theFolder
    else
        return POSIX path of (desktop as alias)
    end if
end tell
' 2>/dev/null)

[ -z "$FOLDER" ] && exit 1

# Read cycle state per folder
mkdir -p "$STATE_DIR"
FOLDER_HASH=$(echo -n "$FOLDER" | md5 | head -c 8)
CYCLE_FILE="$STATE_DIR/cycle_$FOLDER_HASH"
IDX=0
[ -f "$CYCLE_FILE" ] && IDX=$(cat "$CYCLE_FILE")
SEEK=${POSITIONS[$IDX]}
NEXT_IDX=$(( (IDX + 1) % ${#POSITIONS[@]} ))
echo "$NEXT_IDX" > "$CYCLE_FILE"
NEXT_SEEK=${POSITIONS[$NEXT_IDX]}

# Count videos
COUNT=$(find "$FOLDER" -maxdepth 1 \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.3gp" -o -iname "*.vob" -o -iname "*.ts" -o -iname "*.mts" -o -iname "*.ogv" \) 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" -eq 0 ] && { osascript -e 'display notification "No videos found" with title "VidIcon"'; exit 0; }

osascript -e "display notification \"${SEEK}% → next: ${NEXT_SEEK}%\" with title \"VidIcon ⏳ $COUNT videos\""

/usr/local/bin/vidicon icons "$FOLDER" --seek "$SEEK" 2>/dev/null

# Force Finder to refresh icons by toggling the folder view
killall Finder 2>/dev/null
sleep 0.5

osascript -e "display notification \"Done at ${SEEK}% • press again for ${NEXT_SEEK}%\" with title \"VidIcon ✅\" sound name \"Glass\""
