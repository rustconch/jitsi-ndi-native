/**
 * salutejazz-ndi-bridge
 *
 * Tiny native binding around NDI 6 SDK that accepts decoded media frames
 * (such as those produced by Chromium's MediaStreamTrackProcessor) and
 * publishes them onto the network as NDI sources.
 *
 * One sender = one NDI source = one (participant, mediaType) tuple.
 */

/** Opaque handle to a native NDIlib_send_instance. */
export type NdiSenderHandle = unknown;

/** NDI FourCC video format tags supported by this binding. */
export interface FourCCMap {
  /** Y plane followed by interleaved CbCr (camera default in Chromium). */
  NV12: number;
  /** Y, then U, then V planes (yuv420p). */
  I420: number;
  /** Y, then V, then U planes. */
  YV12: number;
  /** 4:2:2 packed YCbCr. */
  UYVY: number;
  /** 32-bit BGRA, premultiplied alpha. */
  BGRA: number;
  /** 32-bit BGRX (no alpha). */
  BGRX: number;
  /** 32-bit RGBA. */
  RGBA: number;
  /** 32-bit RGBX. */
  RGBX: number;
}

export interface CreateSenderOptions {
  /** When true, NDI rate-limits video to its frame rate. Default true. */
  clockVideo?: boolean;
  /** When true, NDI rate-limits audio. Default false (we drive audio ourselves). */
  clockAudio?: boolean;
}

/** Create an NDI sender by name. Throws if NDI runtime is not available. */
export function createSender(
  sourceName: string,
  options?: CreateSenderOptions
): NdiSenderHandle;

/**
 * Hint to release the underlying NDI sender. Calling this is optional —
 * V8 finalizer will release the resource when the handle is GC'd. Use
 * explicit destroy when you need to free immediately (e.g. participant
 * left the room).
 */
export function destroySender(handle: NdiSenderHandle): void;

/**
 * Push a single video frame to NDI. The buffer may be released by the caller
 * as soon as this function returns — NDI copies the frame internally.
 *
 * For planar formats (NV12/I420/YV12) the buffer must contain ALL planes
 * concatenated in the format's natural order, and `strideOrSize` is the
 * stride of the Y plane (NDI infers chroma strides from format + width).
 * For packed formats the buffer is a single plane and `strideOrSize` is
 * the line stride in bytes.
 */
export function sendVideo(
  handle: NdiSenderHandle,
  buffer: Uint8Array | Buffer,
  width: number,
  height: number,
  strideOrSize: number,
  fourCC: number,
  frameRateN: number,
  frameRateD: number,
  timecode100ns?: number
): boolean;

/**
 * Push a single audio frame to NDI. Format is FLTP — planar 32-bit float,
 * channel_stride_in_bytes between consecutive channels.
 *
 * Chromium's AudioData with format='f32-planar' lays out exactly this way.
 */
export function sendAudio(
  handle: NdiSenderHandle,
  planar: Float32Array | Buffer,
  sampleRate: number,
  numChannels: number,
  numSamples: number,
  channelStrideBytes?: number,
  timecode100ns?: number
): boolean;

export const FourCC: FourCCMap;
