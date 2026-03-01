#!/bin/bash
# vidicon-finder: Get current Finder folder and set video icons
# Called by Karabiner keyboard shortcut

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

COUNT=$(find "$FOLDER" -maxdepth 1 \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.3gp" -o -iname "*.vob" -o -iname "*.ts" -o -iname "*.mts" -o -iname "*.m2ts" -o -iname "*.ogv" -o -iname "*.rmvb" -o -iname "*.divx" -o -iname "*.f4v" -o -iname "*.asf" \) 2>/dev/null | wc -l | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    osascript -e "display notification \"No video files found\" with title \"VidIcon\" sound name \"Basso\""
    exit 0
fi

osascript -e "display notification \"Processing $COUNT videos...\" with title \"VidIcon ⏳\""

/usr/local/bin/vidicon icons "$FOLDER" 2>/dev/null

osascript -e 'tell application "Finder" to activate'
osascript -e "display notification \"$COUNT video icons updated!\" with title \"VidIcon ✅\" sound name \"Glass\""
