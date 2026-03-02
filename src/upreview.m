/*
 * VidIcon - Rich video thumbnails for macOS Finder
 *
 * Usage:
 *   vidicon icons <folder> [--recursive]                 - Set Finder icons
 *   vidicon info <video>                                 - Show video metadata
 *   vidicon thumbnail <video> [output.png] [width]       - Extract thumbnail
 *   vidicon ql <video> [--full]                          - Quick Look preview
 *
 * Uses FFmpeg C libraries for maximum codec support.
 */

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Cocoa/Cocoa.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// ---- Frame extraction using FFmpeg ----

static CGImageRef extract_frame(const char *filePath, int maxWidth,
                                double seekPercent) {
  AVFormatContext *fmtCtx = NULL;
  const AVCodec *codec = NULL;
  AVCodecContext *codecCtx = NULL;
  AVFrame *frame = NULL;
  AVFrame *rgbFrame = NULL;
  AVPacket *pkt = NULL;
  struct SwsContext *swsCtx = NULL;
  CGImageRef image = NULL;
  int videoStream = -1;

  if (avformat_open_input(&fmtCtx, filePath, NULL, NULL) < 0)
    return NULL;
  if (avformat_find_stream_info(fmtCtx, NULL) < 0) {
    avformat_close_input(&fmtCtx);
    return NULL;
  }

  for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
    if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      videoStream = (int)i;
      break;
    }
  }
  if (videoStream < 0) {
    avformat_close_input(&fmtCtx);
    return NULL;
  }

  codec =
      avcodec_find_decoder(fmtCtx->streams[videoStream]->codecpar->codec_id);
  if (!codec) {
    avformat_close_input(&fmtCtx);
    return NULL;
  }

  codecCtx = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(codecCtx,
                                fmtCtx->streams[videoStream]->codecpar);
  if (avcodec_open2(codecCtx, codec, NULL) < 0) {
    avcodec_free_context(&codecCtx);
    avformat_close_input(&fmtCtx);
    return NULL;
  }

  // Seek
  int64_t duration = fmtCtx->duration;
  if (duration > 0 && seekPercent > 0) {
    int64_t seekTarget = (int64_t)(duration * seekPercent);
    if (seekTarget < AV_TIME_BASE)
      seekTarget = AV_TIME_BASE;
    if (seekTarget > duration - AV_TIME_BASE)
      seekTarget = duration - AV_TIME_BASE;
    av_seek_frame(fmtCtx, -1, seekTarget, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(codecCtx);
  }

  frame = av_frame_alloc();
  rgbFrame = av_frame_alloc();
  pkt = av_packet_alloc();
  if (!frame || !rgbFrame || !pkt)
    goto cleanup;

  int gotFrame = 0;
  int maxPackets = 500;
  while (maxPackets-- > 0) {
    int ret = av_read_frame(fmtCtx, pkt);
    if (ret < 0) {
      if (!gotFrame && duration > 0) {
        av_seek_frame(fmtCtx, -1, 0, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(codecCtx);
        maxPackets = 100;
        duration = 0;
        continue;
      }
      break;
    }
    if (pkt->stream_index != videoStream) {
      av_packet_unref(pkt);
      continue;
    }

    ret = avcodec_send_packet(codecCtx, pkt);
    av_packet_unref(pkt);
    if (ret < 0)
      continue;

    ret = avcodec_receive_frame(codecCtx, frame);
    if (ret == 0) {
      gotFrame = 1;
      break;
    }
  }

  if (!gotFrame)
    goto cleanup;

  int srcW = frame->width, srcH = frame->height;
  int dstW, dstH;
  if (maxWidth <= 0)
    maxWidth = 512;
  if (srcW > maxWidth) {
    dstW = maxWidth;
    dstH = (int)((double)srcH * maxWidth / srcW);
    if (dstH % 2 != 0)
      dstH++;
  } else {
    dstW = srcW;
    dstH = srcH;
  }

  swsCtx = sws_getContext(srcW, srcH, frame->format, dstW, dstH,
                          AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
  if (!swsCtx)
    goto cleanup;

  int rgbBufSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, dstW, dstH, 1);
  uint8_t *rgbBuf = (uint8_t *)av_malloc(rgbBufSize);
  if (!rgbBuf)
    goto cleanup;

  av_image_fill_arrays(rgbFrame->data, rgbFrame->linesize, rgbBuf,
                       AV_PIX_FMT_RGBA, dstW, dstH, 1);
  sws_scale(swsCtx, (const uint8_t *const *)frame->data, frame->linesize, 0,
            srcH, rgbFrame->data, rgbFrame->linesize);

  // Copy pixel data to a malloc'd buffer so CGImage can own it safely
  size_t rowBytes = rgbFrame->linesize[0];
  size_t totalBytes = rowBytes * dstH;
  uint8_t *pixelCopy = (uint8_t *)malloc(totalBytes);
  if (!pixelCopy) {
    av_free(rgbBuf);
    goto cleanup;
  }
  memcpy(pixelCopy, rgbBuf, totalBytes);
  av_free(rgbBuf); // Free the FFmpeg buffer now — we have our copy

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  // Use a release callback so the pixel data gets freed when CGImage is
  // released
  CGDataProviderRef provider = CGDataProviderCreateWithData(
      NULL, pixelCopy, totalBytes, (CGDataProviderReleaseDataCallback)free);

  if (colorSpace && provider) {
    image = CGImageCreate(dstW, dstH, 8, 32, rowBytes, colorSpace,
                          kCGBitmapByteOrderDefault |
                              kCGImageAlphaPremultipliedLast,
                          provider, NULL, false, kCGRenderingIntentDefault);
  } else {
    free(pixelCopy); // Only free manually if provider wasn't created
  }
  if (provider)
    CGDataProviderRelease(provider);
  if (colorSpace)
    CGColorSpaceRelease(colorSpace);

cleanup:
  if (swsCtx)
    sws_freeContext(swsCtx);
  if (pkt)
    av_packet_free(&pkt);
  if (frame)
    av_frame_free(&frame);
  if (rgbFrame)
    av_frame_free(&rgbFrame);
  if (codecCtx)
    avcodec_free_context(&codecCtx);
  if (fmtCtx)
    avformat_close_input(&fmtCtx);
  return image;
}

// ---- Save CGImage as PNG ----

static int save_as_png(CGImageRef image, const char *outputPath) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8 *)outputPath, strlen(outputPath),
      false);
  if (!url)
    return -1;

  CGImageDestinationRef dest =
      CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);
  CFRelease(url);
  if (!dest)
    return -1;

  CGImageDestinationAddImage(dest, image, NULL);
  Boolean ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? 0 : -1;
}

// ---- Video info ----

static void print_video_info(const char *filePath) {
  AVFormatContext *fmtCtx = NULL;
  if (avformat_open_input(&fmtCtx, filePath, NULL, NULL) < 0) {
    fprintf(stderr, "Error: Cannot open file\n");
    return;
  }
  if (avformat_find_stream_info(fmtCtx, NULL) < 0) {
    avformat_close_input(&fmtCtx);
    return;
  }

  printf("📁 File: %s\n", filePath);
  if (fmtCtx->iformat)
    printf("📦 Format: %s (%s)\n", fmtCtx->iformat->long_name ?: "Unknown",
           fmtCtx->iformat->name ?: "");

  double duration =
      (fmtCtx->duration > 0) ? (double)fmtCtx->duration / AV_TIME_BASE : 0;
  if (duration > 0) {
    int h = (int)(duration / 3600);
    int m = (int)((duration - h * 3600) / 60);
    int s = (int)(duration - h * 3600 - m * 60);
    printf("⏱  Duration: %d:%02d:%02d\n", h, m, s);
  }

  struct stat st;
  if (stat(filePath, &st) == 0) {
    if (st.st_size >= 1073741824LL)
      printf("💾 Size: %.1f GB\n", st.st_size / 1073741824.0);
    else if (st.st_size >= 1048576LL)
      printf("💾 Size: %.1f MB\n", st.st_size / 1048576.0);
    else
      printf("💾 Size: %.0f KB\n", st.st_size / 1024.0);
  }

  if (fmtCtx->bit_rate > 0)
    printf("📊 Bitrate: %.0f kbps\n", fmtCtx->bit_rate / 1000.0);

  printf("\n");
  for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
    AVCodecParameters *par = fmtCtx->streams[i]->codecpar;
    const AVCodec *c = avcodec_find_decoder(par->codec_id);

    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
      printf("🎬 Video: %s", c ? c->long_name : "Unknown");
      if (par->width > 0)
        printf(" (%dx%d)", par->width, par->height);
      AVRational fps = fmtCtx->streams[i]->avg_frame_rate;
      if (fps.den > 0 && fps.num > 0)
        printf(" @ %.1f fps", (double)fps.num / fps.den);
      printf("\n");
    } else if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
      printf("🔊 Audio: %s", c ? c->long_name : "Unknown");
      if (par->sample_rate > 0)
        printf(" %d Hz", par->sample_rate);
      if (par->ch_layout.nb_channels > 0)
        printf(", %d ch", par->ch_layout.nb_channels);
      printf("\n");
    } else if (par->codec_type == AVMEDIA_TYPE_SUBTITLE) {
      printf("📝 Subtitle: %s\n", c ? c->long_name : "Unknown");
    }
  }

  avformat_close_input(&fmtCtx);
}

// ---- Preview window using AVKit ----

static void open_preview_window(const char *filePath) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // Try native AVPlayer first
    NSString *path = [NSString stringWithUTF8String:filePath];
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    AVPlayer *player = [AVPlayer playerWithURL:fileURL];

    // Check if can play
    AVPlayerItem *item = player.currentItem;
    if (item && item.status != AVPlayerItemStatusFailed) {
      // Create window with AVPlayerView
      NSRect frame = NSMakeRect(100, 100, 960, 540);
      NSWindow *window = [[NSWindow alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskTitled |
                               NSWindowStyleMaskClosable |
                               NSWindowStyleMaskResizable |
                               NSWindowStyleMaskMiniaturizable)
                      backing:NSBackingStoreBuffered
                        defer:NO];

      NSString *title = [path lastPathComponent];
      [window setTitle:[NSString stringWithFormat:@"Preview: %@", title]];

      AVPlayerView *playerView = [[AVPlayerView alloc] initWithFrame:frame];
      playerView.player = player;
      playerView.controlsStyle = AVPlayerViewControlsStyleDefault;
      [window setContentView:playerView];
      [window makeKeyAndOrderFront:nil];
      [player play];

      [NSApp activateIgnoringOtherApps:YES];
      [NSApp run];
      return;
    }

    // Fallback: show poster frame with metadata
    CGImageRef posterImage = extract_frame(filePath, 960, 0.10);
    if (!posterImage) {
      fprintf(stderr, "Error: Could not extract frame from video\n");
      return;
    }

    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithCGImage:posterImage];
    NSImage *nsImage = [[NSImage alloc]
        initWithSize:NSMakeSize(CGImageGetWidth(posterImage),
                                CGImageGetHeight(posterImage))];
    [nsImage addRepresentation:rep];
    CGImageRelease(posterImage);

    NSRect frame =
        NSMakeRect(100, 100, nsImage.size.width, nsImage.size.height + 40);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    NSString *title =
        [[NSString stringWithUTF8String:filePath] lastPathComponent];
    [window setTitle:[NSString stringWithFormat:@"Preview: %@", title]];

    NSImageView *imageView =
        [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, nsImage.size.width,
                                                      nsImage.size.height)];
    imageView.image = nsImage;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [window.contentView addSubview:imageView];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
  }
}

// ---- Batch thumbnail generation ----

static int is_video_extension(const char *filename) {
  const char *ext = strrchr(filename, '.');
  if (!ext)
    return 0;
  ext++;

  // All known video container extensions
  const char *videoExts[] = {// Common
                             "mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv",
                             "webm",
                             // MPEG
                             "mpg", "mpeg", "mpe", "m2v", "mpv", "m1v",
                             // Transport streams
                             "ts", "mts", "m2ts", "mxf",
                             // Mobile/legacy
                             "3gp", "3g2", "3gpp", "3gpp2",
                             // OGG/Theora
                             "ogv", "ogg",
                             // Real/DivX/Misc
                             "rmvb", "rm", "divx", "f4v", "f4p",
                             // DVD/Blu-ray
                             "vob", "evo",
                             // Others
                             "asf", "swf", "amv", "dv", "drc", "gif", "mxf",
                             "nut", "nsv", "yuv", "y4m",
                             // AVCHD
                             "mod", "tod",
                             // Rare but valid
                             "bik", "roq", "svi", "smk", NULL};

  for (int i = 0; videoExts[i]; i++) {
    if (strcasecmp(ext, videoExts[i]) == 0) {
      // For .ts files, skip small files (likely TypeScript)
      if (strcasecmp(ext, "ts") == 0) {
        struct stat st;
        if (stat(filename, &st) == 0 && st.st_size < 100000)
          return 0;
      }
      return 1;
    }
  }
  return 0;
}

static void batch_thumbnails(const char *folder, int recursive, int width) {
  DIR *dir = opendir(folder);
  if (!dir) {
    fprintf(stderr, "Error: Cannot open folder: %s\n", folder);
    return;
  }

  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (entry->d_name[0] == '.')
      continue;

    char fullPath[4096];
    snprintf(fullPath, sizeof(fullPath), "%s/%s", folder, entry->d_name);

    struct stat st;
    if (stat(fullPath, &st) != 0)
      continue;

    if (S_ISDIR(st.st_mode) && recursive) {
      batch_thumbnails(fullPath, recursive, width);
      continue;
    }

    if (!S_ISREG(st.st_mode))
      continue;
    if (!is_video_extension(entry->d_name))
      continue;

    // Generate thumbnail
    char outputPath[4096];
    snprintf(outputPath, sizeof(outputPath), "%s/%s.thumb.png", folder,
             entry->d_name);

    // Skip if thumbnail already exists and is newer
    struct stat thumbSt;
    if (stat(outputPath, &thumbSt) == 0 && thumbSt.st_mtime >= st.st_mtime) {
      printf("⏭  Skip (exists): %s\n", entry->d_name);
      continue;
    }

    printf("🔨 Generating: %s ... ", entry->d_name);
    fflush(stdout);

    CGImageRef image = extract_frame(fullPath, width, 0.10);
    if (image) {
      if (save_as_png(image, outputPath) == 0) {
        printf("✅\n");
      } else {
        printf("❌ (save failed)\n");
      }
      CGImageRelease(image);
    } else {
      printf("❌ (extraction failed)\n");
    }
  }

  closedir(dir);
}

// ---- Rich Finder Icon with metadata overlays ----

typedef struct {
  char codec[64];
  int width;
  int height;
  double duration;
  off_t fileSize;
} IconVideoInfo;

static int get_icon_video_info(const char *filePath, IconVideoInfo *info) {
  memset(info, 0, sizeof(IconVideoInfo));

  struct stat st;
  if (stat(filePath, &st) == 0)
    info->fileSize = st.st_size;

  AVFormatContext *fmtCtx = NULL;
  if (avformat_open_input(&fmtCtx, filePath, NULL, NULL) < 0)
    return -1;
  if (avformat_find_stream_info(fmtCtx, NULL) < 0) {
    avformat_close_input(&fmtCtx);
    return -1;
  }

  if (fmtCtx->duration > 0)
    info->duration = (double)fmtCtx->duration / AV_TIME_BASE;

  for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
    if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      AVCodecParameters *par = fmtCtx->streams[i]->codecpar;
      const AVCodec *c = avcodec_find_decoder(par->codec_id);
      if (c && c->name)
        strncpy(info->codec, c->name, sizeof(info->codec) - 1);
      info->width = par->width;
      info->height = par->height;
      break;
    }
  }
  avformat_close_input(&fmtCtx);
  return 0;
}

static void draw_text_at(CGContextRef ctx, const char *text, CGFloat x,
                         CGFloat y, CGFloat fontSize, CGFloat r, CGFloat g,
                         CGFloat b, CGFloat a, int bold) {
  @autoreleasepool {
    NSString *str = [NSString stringWithUTF8String:text];
    NSFont *font = bold ? [NSFont boldSystemFontOfSize:fontSize]
                        : [NSFont systemFontOfSize:fontSize];
    NSDictionary *attrs = @{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName : [NSColor colorWithRed:r
                                                       green:g
                                                        blue:b
                                                       alpha:a]
    };

    // Draw with NSString in flipped context
    NSGraphicsContext *nsCtx =
        [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsCtx];
    [str drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
  }
}

static void draw_rounded_badge(CGContextRef ctx, CGFloat x, CGFloat y,
                               CGFloat w, CGFloat h, CGFloat r, CGFloat g,
                               CGFloat b, CGFloat a, CGFloat radius) {
  CGRect rect = CGRectMake(x, y, w, h);
  CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
  CGContextSetRGBFillColor(ctx, r, g, b, a);
  CGContextAddPath(ctx, path);
  CGContextFillPath(ctx);
  CGPathRelease(path);
}

static NSImage *create_rich_icon(CGImageRef frameImage, IconVideoInfo *info,
                                 int iconSize) {
  @autoreleasepool {
    CGFloat W = iconSize, H = iconSize;
    size_t frameW = CGImageGetWidth(frameImage);
    size_t frameH = CGImageGetHeight(frameImage);

    // Create drawing context
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(W, H)];
    [image lockFocus];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    // 1. Draw rounded rect clip for the entire icon
    CGFloat cornerRadius = W * 0.06;
    CGPathRef clipPath = CGPathCreateWithRoundedRect(
        CGRectMake(0, 0, W, H), cornerRadius, cornerRadius, NULL);
    CGContextAddPath(ctx, clipPath);
    CGContextClip(ctx);
    CGPathRelease(clipPath);

    // 2. Fill background black
    CGContextSetRGBFillColor(ctx, 0.08, 0.08, 0.12, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

    // 3. Draw video frame (scaled to fill, centered)
    CGFloat scale;
    CGFloat drawW, drawH, drawX, drawY;
    CGFloat aspect = (CGFloat)frameW / (CGFloat)frameH;
    CGFloat iconAspect = W / H;

    if (aspect > iconAspect) {
      // Frame is wider — fit height, crop sides
      drawH = H;
      drawW = H * aspect;
      drawX = (W - drawW) / 2.0;
      drawY = 0;
    } else {
      // Frame is taller — fit width, crop top/bottom
      drawW = W;
      drawH = W / aspect;
      drawX = 0;
      drawY = (H - drawH) / 2.0;
    }
    CGContextDrawImage(ctx, CGRectMake(drawX, drawY, drawW, drawH), frameImage);

    // 4. Draw bottom gradient bar (for metadata)
    CGFloat barHeight = H * 0.28;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat gradColors[] = {
        0, 0, 0, 0.0,  // transparent at top
        0, 0, 0, 0.85, // dark at bottom
    };
    CGGradientRef gradient =
        CGGradientCreateWithColorComponents(colorSpace, gradColors, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, barHeight),
                                CGPointMake(0, 0), 0);
    CGGradientRelease(gradient);

    // 5. Draw top-right duration badge
    if (info->duration > 0) {
      char durText[32];
      int h = (int)(info->duration / 3600);
      int m = (int)((info->duration - h * 3600) / 60);
      int s = (int)(info->duration - h * 3600 - m * 60);
      if (h > 0)
        snprintf(durText, sizeof(durText), "%d:%02d:%02d", h, m, s);
      else
        snprintf(durText, sizeof(durText), "%d:%02d", m, s);

      CGFloat badgeFontSize = W * 0.07;
      CGFloat badgeH = badgeFontSize * 1.7;
      CGFloat badgeW =
          strlen(durText) * badgeFontSize * 0.65 + badgeFontSize * 0.8;
      CGFloat badgeX = W - badgeW - W * 0.03;
      CGFloat badgeY = H - badgeH - H * 0.03;

      draw_rounded_badge(ctx, badgeX, badgeY, badgeW, badgeH, 0.0, 0.0, 0.0,
                         0.7, badgeH * 0.3);
      draw_text_at(ctx, durText, badgeX + badgeFontSize * 0.4,
                   badgeY + badgeH * 0.22, badgeFontSize, 1.0, 1.0, 1.0, 0.95,
                   1);
    }

    // 6. Draw bottom info text
    CGFloat textY = H * 0.04;
    CGFloat leftX = W * 0.04;
    CGFloat smallFont = W * 0.058;

    // Resolution
    if (info->width > 0 && info->height > 0) {
      char resText[32];
      if (info->height >= 2160)
        snprintf(resText, sizeof(resText), "4K");
      else if (info->height >= 1440)
        snprintf(resText, sizeof(resText), "2K");
      else if (info->height >= 1080)
        snprintf(resText, sizeof(resText), "1080p");
      else if (info->height >= 720)
        snprintf(resText, sizeof(resText), "720p");
      else if (info->height >= 480)
        snprintf(resText, sizeof(resText), "480p");
      else
        snprintf(resText, sizeof(resText), "%dp", info->height);

      draw_rounded_badge(ctx, leftX, textY,
                         strlen(resText) * smallFont * 0.65 + smallFont * 0.6,
                         smallFont * 1.5, 0.2, 0.5, 1.0, 0.8, smallFont * 0.4);
      draw_text_at(ctx, resText, leftX + smallFont * 0.3,
                   textY + smallFont * 0.15, smallFont * 0.85, 1.0, 1.0, 1.0,
                   1.0, 1);
      leftX += strlen(resText) * smallFont * 0.65 + smallFont * 0.8;
    }

    // Codec
    if (info->codec[0]) {
      char codecLabel[32];
      if (strcasecmp(info->codec, "hevc") == 0 ||
          strcasecmp(info->codec, "h265") == 0)
        snprintf(codecLabel, sizeof(codecLabel), "HEVC");
      else if (strcasecmp(info->codec, "h264") == 0)
        snprintf(codecLabel, sizeof(codecLabel), "H.264");
      else if (strcasecmp(info->codec, "vp9") == 0)
        snprintf(codecLabel, sizeof(codecLabel), "VP9");
      else if (strcasecmp(info->codec, "av1") == 0)
        snprintf(codecLabel, sizeof(codecLabel), "AV1");
      else {
        strncpy(codecLabel, info->codec, sizeof(codecLabel) - 1);
        // Uppercase first letter
        if (codecLabel[0] >= 'a' && codecLabel[0] <= 'z')
          codecLabel[0] -= 32;
      }

      draw_rounded_badge(ctx, leftX, textY,
                         strlen(codecLabel) * smallFont * 0.6 + smallFont * 0.6,
                         smallFont * 1.5, 0.6, 0.2, 0.8, 0.8, smallFont * 0.4);
      draw_text_at(ctx, codecLabel, leftX + smallFont * 0.3,
                   textY + smallFont * 0.15, smallFont * 0.85, 1.0, 1.0, 1.0,
                   1.0, 1);
      leftX += strlen(codecLabel) * smallFont * 0.6 + smallFont * 0.8;
    }

    // File size
    if (info->fileSize > 0) {
      char sizeText[32];
      if (info->fileSize >= 1073741824LL)
        snprintf(sizeText, sizeof(sizeText), "%.1fG",
                 info->fileSize / 1073741824.0);
      else if (info->fileSize >= 104857600LL) // > 100MB
        snprintf(sizeText, sizeof(sizeText), "%.0fM",
                 info->fileSize / 1048576.0);
      else if (info->fileSize >= 1048576LL)
        snprintf(sizeText, sizeof(sizeText), "%.1fM",
                 info->fileSize / 1048576.0);
      else
        snprintf(sizeText, sizeof(sizeText), "%.0fK", info->fileSize / 1024.0);

      draw_rounded_badge(ctx, leftX, textY,
                         strlen(sizeText) * smallFont * 0.6 + smallFont * 0.6,
                         smallFont * 1.5, 0.15, 0.15, 0.2, 0.75,
                         smallFont * 0.4);
      draw_text_at(ctx, sizeText, leftX + smallFont * 0.3,
                   textY + smallFont * 0.15, smallFont * 0.85, 0.85, 0.85, 0.9,
                   1.0, 0);
    }

    // 7. Draw play button in center
    CGFloat playR = W * 0.1;
    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.45);
    CGContextFillEllipseInRect(
        ctx, CGRectMake(W / 2 - playR, H / 2 - playR, playR * 2, playR * 2));
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.9);
    CGFloat tri = playR * 0.55;
    CGContextMoveToPoint(ctx, W / 2 - tri * 0.35, H / 2 - tri);
    CGContextAddLineToPoint(ctx, W / 2 - tri * 0.35, H / 2 + tri);
    CGContextAddLineToPoint(ctx, W / 2 + tri * 0.75, H / 2);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    CGColorSpaceRelease(colorSpace);
    [image unlockFocus];
    return image;
  }
}

static void set_rich_finder_icon(const char *filePath, int iconSize,
                                 double seekPct) {
  IconVideoInfo info;
  get_icon_video_info(filePath, &info);

  CGImageRef frame = extract_frame(filePath, iconSize, seekPct);
  if (!frame)
    return;

  NSImage *richIcon = create_rich_icon(frame, &info, iconSize);
  CGImageRelease(frame);

  if (richIcon) {
    @autoreleasepool {
      NSString *path = [NSString stringWithUTF8String:filePath];
      [[NSWorkspace sharedWorkspace] setIcon:richIcon forFile:path options:0];
    }
  }
}

static void batch_set_icons(const char *folder, int recursive, int width,
                            double seekPct) {
  DIR *dir = opendir(folder);
  if (!dir) {
    fprintf(stderr, "Error: Cannot open folder: %s\n", folder);
    return;
  }

  // Collect all video file paths first
  char **files = NULL;
  int fileCount = 0;
  int fileCapacity = 64;
  files = (char **)malloc(fileCapacity * sizeof(char *));

  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (entry->d_name[0] == '.')
      continue;

    char fullPath[4096];
    snprintf(fullPath, sizeof(fullPath), "%s/%s", folder, entry->d_name);

    struct stat st;
    if (stat(fullPath, &st) != 0)
      continue;

    if (S_ISDIR(st.st_mode) && recursive) {
      batch_set_icons(fullPath, recursive, width, seekPct);
      continue;
    }

    if (!S_ISREG(st.st_mode))
      continue;
    if (!is_video_extension(entry->d_name))
      continue;

    if (fileCount >= fileCapacity) {
      fileCapacity *= 2;
      files = (char **)realloc(files, fileCapacity * sizeof(char *));
    }
    files[fileCount++] = strdup(fullPath);
  }
  closedir(dir);

  if (fileCount == 0) {
    free(files);
    return;
  }

  printf("\xf0\x9f\x9a\x80 Processing %d videos in parallel...\n", fileCount);
  fflush(stdout);

  __block int32_t done = 0;
  int total = fileCount;

  // Use dispatch_apply for parallel iteration with automatic thread management
  dispatch_queue_t queue = dispatch_queue_create("com.vidicon.batch", DISPATCH_QUEUE_CONCURRENT);
  dispatch_semaphore_t sem = dispatch_semaphore_create(4); // max 4 concurrent

  dispatch_apply(fileCount, queue, ^(size_t idx) {
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    @autoreleasepool {
      set_rich_finder_icon(files[idx], width, seekPct);
      int32_t d = OSAtomicIncrement32(&done);
      const char *name = strrchr(files[idx], '/');
      name = name ? name + 1 : files[idx];
      printf("  \xe2\x9c\x85 [%d/%d] %s\n", d, total, name);
      fflush(stdout);
    }
    dispatch_semaphore_signal(sem);
  });

  // Cleanup
  for (int i = 0; i < fileCount; i++)
    free(files[i]);
  free(files);

  printf("\n\xf0\x9f\x93\x8a Done: %d icons (frame at %d%%)\n", total, (int)(seekPct * 100));
}

// ---- Quick Look preview (remux to MOV + open qlmanage) ----

#define FFMPEG_BIN "/usr/local/bin/ffmpeg"
#define FFPROBE_BIN "/usr/local/bin/ffprobe"
#define MAX_QL_DURATION 60 // First 60 seconds

static void get_ql_cache_dir(char *buf, size_t bufsize) {
  const char *home = getenv("HOME");
  if (!home)
    home = "/tmp";
  snprintf(buf, bufsize, "%s/Library/Caches/VidIcon", home);
}

static void get_ql_cache_path(const char *filePath, char *cachePath,
                              size_t size) {
  char cacheDir[2048];
  get_ql_cache_dir(cacheDir, sizeof(cacheDir));

  struct stat st;
  unsigned long mtime = 0;
  if (stat(filePath, &st) == 0)
    mtime = (unsigned long)st.st_mtime;

  unsigned long hash = mtime;
  for (const char *p = filePath; *p; p++)
    hash = hash * 31 + (unsigned char)*p;

  snprintf(cachePath, size, "%s/%lx.mov", cacheDir, hash);
}

static int is_ql_native_codec(const char *codec) {
  return (strcasecmp(codec, "h264") == 0 || strcasecmp(codec, "hevc") == 0 ||
          strcasecmp(codec, "h265") == 0 || strcasecmp(codec, "mpeg4") == 0 ||
          strcasecmp(codec, "prores") == 0);
}

static void quicklook_preview(const char *filePath, int fullLength) {
  // Check if the file is already a MOV/MP4 that macOS can natively preview
  const char *ext = strrchr(filePath, '.');
  if (ext && (strcasecmp(ext, ".mov") == 0 || strcasecmp(ext, ".m4v") == 0)) {
    // Native format - open directly
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "qlmanage -p \"%s\" &>/dev/null &", filePath);
    system(cmd);
    return;
  }

  // Get video info to decide remux vs transcode
  AVFormatContext *fmtCtx = NULL;
  if (avformat_open_input(&fmtCtx, filePath, NULL, NULL) < 0) {
    fprintf(stderr, "Error: Cannot open video\n");
    return;
  }
  if (avformat_find_stream_info(fmtCtx, NULL) < 0) {
    avformat_close_input(&fmtCtx);
    return;
  }

  char videoCodec[64] = "";
  double duration =
      (fmtCtx->duration > 0) ? (double)fmtCtx->duration / AV_TIME_BASE : 0;
  for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
    if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      const AVCodec *c =
          avcodec_find_decoder(fmtCtx->streams[i]->codecpar->codec_id);
      if (c && c->name)
        strncpy(videoCodec, c->name, sizeof(videoCodec) - 1);
      break;
    }
  }
  avformat_close_input(&fmtCtx);

  // Create cache dir and path
  char cacheDir[2048], cachePath[2048];
  get_ql_cache_dir(cacheDir, sizeof(cacheDir));
  mkdir(cacheDir, 0755);
  get_ql_cache_path(filePath, cachePath, sizeof(cachePath));

  // Check if cached version exists
  struct stat cacheStat;
  if (stat(cachePath, &cacheStat) == 0 && cacheStat.st_size > 0) {
    printf("⚡ Using cached preview...\n");
  } else {
    // Determine duration limit
    double maxDur = fullLength ? 0 : MAX_QL_DURATION;
    if (duration > 0 && maxDur > 0 && duration < maxDur)
      maxDur = 0; // File shorter than limit

    char cmd[8192];
    if (is_ql_native_codec(videoCodec)) {
      // Fast remux: just change container (stream copy)
      printf("🔄 Remuxing to MOV (fast copy)...\n");
      if (maxDur > 0) {
        snprintf(cmd, sizeof(cmd),
                 "%s -i \"%s\" -t %.0f -c copy -movflags +faststart -y \"%s\" "
                 "2>/dev/null",
                 FFMPEG_BIN, filePath, maxDur, cachePath);
      } else {
        snprintf(
            cmd, sizeof(cmd),
            "%s -i \"%s\" -c copy -movflags +faststart -y \"%s\" 2>/dev/null",
            FFMPEG_BIN, filePath, cachePath);
      }
    } else {
      // Transcode to H.264 for compatibility
      printf("🔄 Transcoding to H.264 (this may take a moment)...\n");
      if (maxDur > 0) {
        snprintf(cmd, sizeof(cmd),
                 "%s -i \"%s\" -t %.0f "
                 "-c:v libx264 -preset fast -crf 23 -c:a aac -b:a 192k "
                 "-vf "
                 "\"scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_"
                 "ratio=decrease\" "
                 "-movflags +faststart -y \"%s\" 2>/dev/null",
                 FFMPEG_BIN, filePath, maxDur, cachePath);
      } else {
        snprintf(cmd, sizeof(cmd),
                 "%s -i \"%s\" "
                 "-c:v libx264 -preset fast -crf 23 -c:a aac -b:a 192k "
                 "-vf "
                 "\"scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_"
                 "ratio=decrease\" "
                 "-movflags +faststart -y \"%s\" 2>/dev/null",
                 FFMPEG_BIN, filePath, cachePath);
      }
    }

    int ret = system(cmd);
    if (ret != 0) {
      fprintf(stderr, "❌ Failed to create preview\n");
      unlink(cachePath);
      return;
    }
    printf("✅ Preview ready!\n");
  }

  // Open in Quick Look
  printf("▶️  Opening Quick Look...\n");
  char qlCmd[4096];
  snprintf(qlCmd, sizeof(qlCmd), "qlmanage -p \"%s\" &>/dev/null &", cachePath);
  system(qlCmd);
}

// ---- Main ----

static void print_usage(void) {
  printf("VidIcon - Rich video thumbnails for macOS Finder\n\n");
  printf("Usage:\n");
  printf("  vidicon icons <folder> [--recursive] [--width N]    Set Finder "
         "icons\n");
  printf("  vidicon info <video>                                Show video "
         "metadata\n");
  printf("  vidicon thumbnail <video> [output.png] [width]      Extract "
         "thumbnail\n");
  printf("  vidicon ql <video> [--full]                         Quick Look "
         "preview\n");
  printf("  vidicon preview <video>                             Open player "
         "window\n");
  printf("  vidicon batch <folder> [--recursive] [--width N]    Generate "
         "thumbnail PNGs\n");
  printf("\n");
  printf("Examples:\n");
  printf("  vidicon icons ~/Movies --recursive                  # Set rich "
         "Finder icons\n");
  printf("  vidicon info movie.mkv                              # Show codec, "
         "duration, etc.\n");
  printf("  vidicon ql movie.mkv                                # Quick Look "
         "first 60s\n");
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      print_usage();
      return 1;
    }

    const char *cmd = argv[1];

    if (strcmp(cmd, "thumbnail") == 0 || strcmp(cmd, "thumb") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing video path\n");
        return 1;
      }

      const char *inputPath = argv[2];
      int width = 512;

      char outputPath[4096];
      if (argc >= 4 && argv[3][0] != '-') {
        strncpy(outputPath, argv[3], sizeof(outputPath) - 1);
      } else {
        snprintf(outputPath, sizeof(outputPath), "%s.thumb.png", inputPath);
      }

      if (argc >= 5)
        width = atoi(argv[4]);
      if (argc >= 4 && argv[3][0] == '-') {
        // Width might be third arg
        width = atoi(argv[3] + (strncmp(argv[3], "--width", 7) == 0 ? 8 : 0));
        if (width <= 0)
          width = 512;
      }

      printf("📸 Extracting thumbnail from: %s\n", inputPath);
      CGImageRef image = extract_frame(inputPath, width, 0.10);
      if (image) {
        if (save_as_png(image, outputPath) == 0) {
          printf("✅ Saved to: %s (%zux%zu)\n", outputPath,
                 CGImageGetWidth(image), CGImageGetHeight(image));
        } else {
          fprintf(stderr, "❌ Failed to save PNG\n");
          CGImageRelease(image);
          return 1;
        }
        CGImageRelease(image);
      } else {
        fprintf(stderr, "❌ Failed to extract frame\n");
        return 1;
      }

    } else if (strcmp(cmd, "info") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing video path\n");
        return 1;
      }
      print_video_info(argv[2]);

    } else if (strcmp(cmd, "preview") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing video path\n");
        return 1;
      }
      open_preview_window(argv[2]);

    } else if (strcmp(cmd, "batch") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing folder path\n");
        return 1;
      }
      int recursive = 0;
      int width = 512;
      for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--recursive") == 0 || strcmp(argv[i], "-r") == 0)
          recursive = 1;
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc)
          width = atoi(argv[++i]);
      }
      batch_thumbnails(argv[2], recursive, width);

    } else if (strcmp(cmd, "icons") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing folder path\n");
        return 1;
      }
      int recursive = 0;
      int width = 512;
      double seekPct = 0.05;
      for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--recursive") == 0 || strcmp(argv[i], "-r") == 0)
          recursive = 1;
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc)
          width = atoi(argv[++i]);
        else if (strcmp(argv[i], "--seek") == 0 && i + 1 < argc)
          seekPct = atoi(argv[++i]) / 100.0;
      }
      printf("\xf0\x9f\x8e\xa8 Setting icons (frame at %d%%):\n",
             (int)(seekPct * 100));
      batch_set_icons(argv[2], recursive, width, seekPct);
      printf("\n💡 If icons don't appear immediately, try: killall Finder\n");

    } else if (strcmp(cmd, "ql") == 0 || strcmp(cmd, "quicklook") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Error: Missing video path\n");
        return 1;
      }
      int fullLength = 0;
      for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--full") == 0 || strcmp(argv[i], "-f") == 0)
          fullLength = 1;
      }
      quicklook_preview(argv[2], fullLength);

    } else {
      fprintf(stderr, "Unknown command: %s\n\n", cmd);
      print_usage();
      return 1;
    }
  }
  return 0;
}
