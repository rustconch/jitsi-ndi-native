// Bridges per-participant MediaStream → MediaStreamTrackProcessor →
// VideoFrame/AudioData → native NDI sender. One NdiPump per (participant, kind).
//
// This is the SaluteJazz-side equivalent of the original
// `PerParticipantNdiRouter::handleRtp` + `FfmpegMediaDecoder` chain — except
// the SDK already gives us decoded frames, so we don't need libdatachannel
// or ffmpeg here.

import type { StreamRecord, MediaKind } from './streamPipeline';

// Loaded lazily so the renderer can run without the native module being built
// (development mode), in which case it falls back to logging only.
type NdiBridge = typeof import('salutejazz-ndi-bridge');

let bridge: NdiBridge | null = null;
let bridgeLoadAttempted = false;

function loadBridge(): NdiBridge | null {
  if (bridgeLoadAttempted) return bridge;
  bridgeLoadAttempted = true;
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    bridge = require('salutejazz-ndi-bridge') as NdiBridge;
  } catch (err) {
    console.warn('[ndi] native bridge not loaded — running in dry-run mode', err);
    bridge = null;
  }
  return bridge;
}

const SAFE_NAME_RE = /[^A-Za-z0-9_\-. ]/g;
function ndiSourceNameFor(rec: StreamRecord): string {
  const safe = rec.participantName.replace(SAFE_NAME_RE, ' ').trim() || rec.participantId;
  switch (rec.mediaType) {
    case 'displayScreen': return `SaluteJazz NDI - ${safe} Screen`;
    case 'audio':         return `SaluteJazz NDI - ${safe}`; // audio joins the participant's source
    case 'video':         return `SaluteJazz NDI - ${safe}`;
  }
}

interface VideoFormatDesc {
  fourCC: number;
  /** Total expected bytes per frame layout (e.g. 1.5 * w * h for NV12/I420). */
  packBytes(width: number, height: number): number;
  /** Pack the planes from a VideoFrame into a single contiguous buffer. */
  pack(frame: VideoFrame): Promise<{ buffer: Uint8Array; stride: number }>;
}

function createVideoFormat(format: VideoPixelFormat | string): VideoFormatDesc | null {
  if (!bridge) return null;
  const f = format as string;
  switch (f) {
    case 'NV12': {
      return {
        fourCC: bridge.FourCC.NV12,
        packBytes: (w, h) => Math.ceil(w * h * 1.5),
        async pack(frame: VideoFrame) {
          const w = frame.codedWidth;
          const h = frame.codedHeight;
          const ySize = w * h;
          const uvSize = w * (h / 2);
          const buf = new Uint8Array(ySize + uvSize);
          await frame.copyTo(buf, {
            layout: [
              { offset: 0, stride: w },
              { offset: ySize, stride: w },
            ],
          });
          return { buffer: buf, stride: w };
        },
      };
    }
    case 'I420': {
      return {
        fourCC: bridge.FourCC.I420,
        packBytes: (w, h) => Math.ceil(w * h * 1.5),
        async pack(frame: VideoFrame) {
          const w = frame.codedWidth;
          const h = frame.codedHeight;
          const ySize = w * h;
          const uvWidth = w >> 1;
          const uvHeight = h >> 1;
          const uvSize = uvWidth * uvHeight;
          const buf = new Uint8Array(ySize + uvSize * 2);
          await frame.copyTo(buf, {
            layout: [
              { offset: 0, stride: w },
              { offset: ySize, stride: uvWidth },
              { offset: ySize + uvSize, stride: uvWidth },
            ],
          });
          return { buffer: buf, stride: w };
        },
      };
    }
    case 'BGRA':
    case 'RGBA': {
      return {
        fourCC: f === 'BGRA' ? bridge.FourCC.BGRA : bridge.FourCC.RGBA,
        packBytes: (w, h) => w * h * 4,
        async pack(frame: VideoFrame) {
          const w = frame.codedWidth;
          const h = frame.codedHeight;
          const buf = new Uint8Array(w * h * 4);
          await frame.copyTo(buf, {
            layout: [{ offset: 0, stride: w * 4 }],
          });
          return { buffer: buf, stride: w * 4 };
        },
      };
    }
    default:
      return null;
  }
}

export class NdiPump {
  private senderHandle: unknown | null = null;
  private videoReader: ReadableStreamDefaultReader<VideoFrame> | null = null;
  private audioReader: ReadableStreamDefaultReader<AudioData> | null = null;
  private aborted = false;
  private framesSent = 0;
  private startedAt = performance.now();

  constructor(
    private readonly record: StreamRecord,
    private readonly opts: {
      enableNdi: boolean;
      onLog?: (level: string, msg: string) => void;
      onStats?: (stats: NdiPumpStats) => void;
    },
  ) {}

  start(): void {
    const tracks = this.record.mediaType === 'audio'
      ? this.record.stream.getAudioTracks()
      : this.record.stream.getVideoTracks();
    if (tracks.length === 0) {
      this.log('warn', `no ${this.record.mediaType} tracks on stream — skipping`);
      return;
    }
    const track = tracks[0];

    if (this.opts.enableNdi) {
      const b = loadBridge();
      if (b) {
        try {
          this.senderHandle = b.createSender(ndiSourceNameFor(this.record), {
            clockVideo: this.record.mediaType !== 'audio',
            clockAudio: this.record.mediaType === 'audio',
          });
          this.log('info', `NDI sender ready: ${ndiSourceNameFor(this.record)}`);
        } catch (err) {
          this.log('error', `failed to create NDI sender: ${(err as Error).message}`);
        }
      }
    }

    if (this.record.mediaType === 'audio') {
      this.startAudio(track as MediaStreamTrack);
    } else {
      this.startVideo(track as MediaStreamTrack);
    }
  }

  async stop(): Promise<void> {
    this.aborted = true;
    try {
      await this.videoReader?.cancel();
      await this.audioReader?.cancel();
    } catch { /* swallow */ }
    if (this.senderHandle && bridge) {
      try { bridge.destroySender(this.senderHandle); } catch { /* swallow */ }
      this.senderHandle = null;
    }
    this.log('info', `pump stopped, sent ${this.framesSent} frames`);
  }

  private async startVideo(track: MediaStreamTrack): Promise<void> {
    if (typeof MediaStreamTrackProcessor === 'undefined') {
      this.log('error', 'MediaStreamTrackProcessor unavailable — Chromium too old?');
      return;
    }
    const proc = new MediaStreamTrackProcessor({ track });
    const reader = proc.readable.getReader();
    this.videoReader = reader;

    let format: VideoFormatDesc | null = null;
    let lastReportTs = performance.now();

    while (!this.aborted) {
      const { value: frame, done } = await reader.read();
      if (done || !frame) break;

      try {
        if (!format) {
          format = createVideoFormat(frame.format ?? 'NV12');
          if (!format && this.opts.enableNdi) {
            this.log('warn', `unsupported VideoFrame format ${frame.format} — pump idling`);
          }
        }

        if (format && this.senderHandle && bridge) {
          const { buffer, stride } = await format.pack(frame);
          // VideoFrame.duration is microseconds. fps = 1e6 / duration. We
          // express it as N/1001 so 29.97 fps lands on 30000/1001 exactly.
          // Treat it as metadata only — real timing comes from the timecode
          // field; NDI receivers use frame rate for playback display.
          const fpsN = frame.duration && frame.duration > 0
            ? Math.round((1_000_000 / frame.duration) * 1001)
            : 30000;
          const fpsD = 1001;
          bridge.sendVideo(
            this.senderHandle,
            buffer,
            frame.codedWidth,
            frame.codedHeight,
            stride,
            format.fourCC,
            fpsN,
            fpsD,
            // VideoFrame.timestamp is microseconds → NDI 100-ns ticks ×10.
            frame.timestamp ? frame.timestamp * 10 : 0,
          );
          this.framesSent++;
        }

        const now = performance.now();
        if (now - lastReportTs > 5000) {
          this.opts.onStats?.(this.snapshot(now));
          lastReportTs = now;
        }
      } finally {
        frame.close();
      }
    }
  }

  private async startAudio(track: MediaStreamTrack): Promise<void> {
    if (typeof MediaStreamTrackProcessor === 'undefined') {
      this.log('error', 'MediaStreamTrackProcessor unavailable for audio — Chromium too old?');
      return;
    }
    const proc = new MediaStreamTrackProcessor({ track });
    const reader = proc.readable.getReader();
    this.audioReader = reader;

    let lastReportTs = performance.now();

    while (!this.aborted) {
      const { value: data, done } = await reader.read();
      if (done || !data) break;

      try {
        if (this.senderHandle && bridge) {
          const channels = data.numberOfChannels;
          const samples = data.numberOfFrames;
          // Allocate planar f32 buffer: channel0_samples, channel1_samples, ...
          const planar = new Float32Array(channels * samples);
          for (let ch = 0; ch < channels; ch++) {
            const view = planar.subarray(ch * samples, (ch + 1) * samples);
            data.copyTo(view, {
              planeIndex: ch,
              format: 'f32-planar',
              frameCount: samples,
            });
          }
          bridge.sendAudio(
            this.senderHandle,
            planar,
            data.sampleRate,
            channels,
            samples,
            samples * 4, // channel stride in bytes
            data.timestamp ? data.timestamp * 10 : 0,
          );
          this.framesSent++;
        }

        const now = performance.now();
        if (now - lastReportTs > 5000) {
          this.opts.onStats?.(this.snapshot(now));
          lastReportTs = now;
        }
      } finally {
        data.close();
      }
    }
  }

  private snapshot(now: number): NdiPumpStats {
    const elapsed = (now - this.startedAt) / 1000;
    return {
      participantId: this.record.participantId,
      participantName: this.record.participantName,
      mediaType: this.record.mediaType,
      framesSent: this.framesSent,
      fps: elapsed > 0 ? this.framesSent / elapsed : 0,
      hasNdiSender: !!this.senderHandle,
    };
  }

  private log(level: string, msg: string): void {
    this.opts.onLog?.(level, `[${this.record.mediaType} ${this.record.participantName}] ${msg}`);
  }
}

export interface NdiPumpStats {
  participantId: string;
  participantName: string;
  mediaType: MediaKind;
  framesSent: number;
  fps: number;
  hasNdiSender: boolean;
}
