param(
  [string]$ProjectRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$file = Join-Path $ProjectRoot "src\FfmpegMediaDecoder.cpp"
if (-not (Test-Path $file)) {
  throw "FfmpegMediaDecoder.cpp not found. Run this script from project root."
}

$src = Get-Content -LiteralPath $file -Raw
$backup = "$file.bak_av1_swdecode_v15_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item -LiteralPath $file -Destination $backup -Force
Write-Host "Backup: $backup"

# Add FFmpeg pixel-format descriptor include.
if ($src -notmatch 'libavutil/pixdesc\.h') {
  if ($src.Contains('#include <libavutil/samplefmt.h>')) {
    $src = $src.Replace('#include <libavutil/samplefmt.h>', '#include <libavutil/samplefmt.h>' + "`r`n" + '#include <libavutil/pixdesc.h>')
  } elseif ($src.Contains('#include <libavutil/imgutils.h>')) {
    $src = $src.Replace('#include <libavutil/imgutils.h>', '#include <libavutil/imgutils.h>' + "`r`n" + '#include <libavutil/pixdesc.h>')
  } else {
    throw "Could not find libavutil include anchor."
  }
}

# Helper: force FFmpeg to select non-hardware pixel formats.
if ($src -notmatch 'jnnChooseSoftwarePixelFormat') {
$helper = @'
AVPixelFormat jnnChooseSoftwarePixelFormat(AVCodecContext* ctx, const AVPixelFormat* pix_fmts) {
    (void)ctx;
    if (!pix_fmts) {
        return AV_PIX_FMT_NONE;
    }

    for (const AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; ++p) {
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(*p);
        if (desc && (desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            continue;
        }
        return *p;
    }

    return pix_fmts[0];
}

'@
  $anchor = 'AVCodecContext* openDecoder(AVCodecID id) {'
  if (-not $src.Contains($anchor)) {
    throw "openDecoder anchor not found."
  }
  $src = $src.Replace($anchor, $helper + $anchor)
}

# Prefer libdav1d/dav1d for AV1 when available. This avoids accidental hardware AV1 decoder selection.
if ($src -notmatch 'avcodec_find_decoder_by_name\("libdav1d"\)') {
$old = @'
const AVCodec* codec = avcodec_find_decoder(id);
    if (!codec) throw std::runtime_error("FFmpeg decoder not found");
'@
$new = @'
const AVCodec* codec = nullptr;
    if (id == AV_CODEC_ID_AV1) {
        codec = avcodec_find_decoder_by_name("libdav1d");
        if (!codec) codec = avcodec_find_decoder_by_name("dav1d");
        if (!codec) codec = avcodec_find_decoder(id);
    } else {
        codec = avcodec_find_decoder(id);
    }
    if (!codec) throw std::runtime_error("FFmpeg decoder not found");
'@
  if ($src.Contains($old)) {
    $src = $src.Replace($old, $new)
  } else {
    $pattern = 'const\s+AVCodec\*\s+codec\s*=\s*avcodec_find_decoder\(id\)\s*;\s*if\s*\(!codec\)\s*throw\s+std::runtime_error\("FFmpeg decoder not found"\)\s*;'
    if ($src -match $pattern) {
      $src = [regex]::Replace($src, $pattern, $new, 1)
    } else {
      throw "Decoder lookup block not found."
    }
  }
}

# Install the software pixel-format callback immediately after avcodec_alloc_context3.
if ($src -notmatch 'ctx->get_format\s*=\s*jnnChooseSoftwarePixelFormat') {
$oldAlloc = @'
if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");
'@
$newAlloc = @'
if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");
    ctx->get_format = jnnChooseSoftwarePixelFormat;
    ctx->thread_count = 0;
    ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
'@
  if ($src.Contains($oldAlloc)) {
    $src = $src.Replace($oldAlloc, $newAlloc)
  } else {
    $pattern = 'if\s*\(!ctx\)\s*throw\s+std::runtime_error\("avcodec_alloc_context3 failed"\)\s*;'
    if ($src -match $pattern) {
      $src = [regex]::Replace($src, $pattern, $newAlloc, 1)
    } else {
      throw "avcodec_alloc_context3 block not found."
    }
  }
}

Set-Content -LiteralPath $file -Value $src -Encoding ASCII
Write-Host "Patched: $file"
Write-Host "Now run: cmake --build build --config Release"
