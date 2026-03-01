#!/bin/bash
# vidicon-finder: Get current Finder folder and set video icons
# Each press cycles through different timeline positions: 5% → 25% → 50% → 75% → 5%
# Called by Karabiner keyboard shortcut

STATE_DIR="$HOME/.config/vidicon"
STATE_FILE="$STATE_DIR/cycle_state"

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

if [ -z "$FOLDER" ]; then
    osascript -e 'display notification "No Finder window found" with title "VidIcon" sound name "Basso"'
    exit 1
fi

# Read and advance cycle state (per folder)
mkdir -p "$STATE_DIR"
FOLDER_HASH=$(echo -n "$FOLDER" | md5 | head -c 8)
CYCLE_FILE="$STATE_DIR/cycle_$FOLDER_HASH"

if [ -f "$CYCLE_FILE" ]; then
    IDX=$(cat "$CYCLE_FILE")
else
    IDX=0
fi

SEEK=${POSITIONS[$IDX]}

# Advance to next position for next press
NEXT_IDX=$(( (IDX + 1) % ${#POSITIONS[@]} ))
echo "$NEXT_IDX" > "$CYCLE_FILE"

# Count videos
COUNT=$(find "$FOLDER" -maxdepth 1 \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.3gp" -o -iname "*.vob" -o -iname "*.ts" -o -iname "*.mts" -o -iname "*.m2ts" -o -iname "*.ogv" -o -iname "*.rmvb" \) 2>/dev/null | wc -l | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    osascript -e "display notification \"No video files found\" with title \"VidIcon\" sound name \"Basso\""
    exit 0
fi

NEXT_SEEK=${POSITIONS[$NEXT_IDX]}
osascript -e "display notification \"$COUNT videos at ${SEEK}% • next: ${NEXT_SEEK}%\" with title \"VidIcon ⏳\""

/usr/local/bin/vidicon icons "$FOLDER" --seek "$SEEK" 2>/dev/null

osascript -e 'tell application "Finder" to activate'
osascript -e "display notification \"Done! Frame at ${SEEK}% • press again for ${NEXT_SEEK}%\" with title \"VidIcon ✅\" sound name \"Glass\""
