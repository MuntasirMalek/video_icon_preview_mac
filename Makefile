# VidIcon - Rich video thumbnails for macOS Finder
# Builds the vidicon CLI tool (linked against FFmpeg C libraries)

CC = clang
TOOL_NAME = vidicon

SRC = src/upreview.m

FFMPEG_CFLAGS := $(shell pkg-config --cflags libavformat libavcodec libavutil libswscale 2>/dev/null)
FFMPEG_LIBS := $(shell pkg-config --libs libavformat libavcodec libavutil libswscale 2>/dev/null)

CFLAGS = -Wall -O2 -arch x86_64 \
         -fobjc-arc \
         -Wno-deprecated-declarations \
         -Wno-unused-parameter \
         -Wno-unused-variable \
         -mmacosx-version-min=12.0 \
         $(FFMPEG_CFLAGS)

LDFLAGS = -framework Cocoa \
          -framework AVFoundation \
          -framework AVKit \
          -framework CoreGraphics \
          -framework CoreServices \
          -framework ImageIO \
          $(FFMPEG_LIBS)

.PHONY: all clean install uninstall

all: $(TOOL_NAME)

$(TOOL_NAME): $(SRC)
	@echo "🔨 Building $(TOOL_NAME)..."
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TOOL_NAME) $(SRC)
	@echo "✅ Built $(TOOL_NAME)"

clean:
	@rm -f $(TOOL_NAME)
	@echo "🧹 Cleaned"

install: all
	@echo "📦 Installing..."
	@cp $(TOOL_NAME) /usr/local/bin/$(TOOL_NAME)
	@chmod +x /usr/local/bin/$(TOOL_NAME)
	@cp vidicon-finder.sh /usr/local/bin/vidicon-finder
	@chmod +x /usr/local/bin/vidicon-finder
	@echo "✅ Installed vidicon and vidicon-finder to /usr/local/bin/"

uninstall:
	@rm -f /usr/local/bin/$(TOOL_NAME)
	@rm -f /usr/local/bin/vidicon-finder
	@echo "✅ Uninstalled"
