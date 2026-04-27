param(
  [string]$ProjectRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$file = Join-Path $ProjectRoot "src\FfmpegMediaDecoder.cpp"
if (-not (Test-Path $file)) {
  throw "Не найден файл: $file. Запусти скрипт из корня D:\MEDIA\Desktop\jitsi-ndi-native или передай -ProjectRoot."
}

$src = Get-Content $file -Raw
$backup = "$file.bak_av1_swdecode_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $file $backup -Force
Write-Host "Backup: $backup"

# 1) AV_PIX_FMT_FLAG_HWACCEL / av_pix_fmt_desc_get
if ($src -notmatch 'libavutil/pixdesc\.h') {
  if ($src -match '#include\s+<libavutil/avutil\.h>') {
    $src = $src -replace '(#include\s+<libavutil/avutil\.h>\s*)', "`$1#include <libavutil/pixdesc.h>`r`n"
  } elseif ($src -match 'extern\s+"C"\s*\{') {
    $src = $src -replace '(extern\s+"C"\s*\{\s*)', "`$1`r`n#include <libavutil/pixdesc.h>`r`n"
  } else {
    throw "Не смог автоматически вставить #include <libavutil/pixdesc.h>"
  }
}

# 2) Helper: never let FFmpeg select hw AV1 pixel format on unsupported platform.
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
  $pattern = '(AVCodecContext\*\s+openDecoder\s*\(\s*AVCodecID\s+id\s*\)\s*\{)'
  if ($src -notmatch $pattern) {
    throw "Не найден openDecoder(AVCodecID id) для вставки software pixel-format helper."
  }
  $src = [regex]::Replace($src, $pattern, $helper + '$1', 1)
}

# 3) Prefer libdav1d for AV1 if the installed FFmpeg has it, otherwise fall back to native av1.
$oldCodecLookup = 'const\s+AVCodec\*\s+codec\s*=\s*avcodec_find_decoder\(id\)\s*;\s*if\s*\(!codec\)\s*throw\s+std::runtime_error\("FFmpeg decoder not found"\)\s*;'
if ($src -match $oldCodecLookup -and $src -notmatch 'avcodec_find_decoder_by_name\("libdav1d"\)') {
$newCodecLookup = @'
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
  $src = [regex]::Replace($src, $oldCodecLookup, $newCodecLookup, 1)
}

# 4) Force software pixel format selection on every opened decoder.
if ($src -notmatch 'ctx->get_format\s*=\s*jnnChooseSoftwarePixelFormat') {
  $allocLine = 'if\s*\(!ctx\)\s*throw\s+std::runtime_error\("avcodec_alloc_context3 failed"\)\s*;'
  if ($src -notmatch $allocLine) {
    throw "Не найден блок avcodec_alloc_context3/openDecoder для установки ctx->get_format."
  }
$allocReplacement = @'
if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");
    ctx->get_format = jnnChooseSoftwarePixelFormat;
    ctx->thread_count = 0;
    ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
'@
  $src = [regex]::Replace($src, $allocLine, $allocReplacement, 1)
}

Set-Content $file $src -Encoding UTF8
Write-Host "Patched: $file"
Write-Host "Now rebuild: cmake --build build --config Release"
