// Ambient types shared between main, preload, and renderer compilation.
// MediaStreamTrackProcessor is a Chromium-only API not in stock TS DOM lib.

export {};

declare global {
  interface Window {
    mainBridge?: {
      log: (level: string, ...args: unknown[]) => void;
    };
  }

  interface MediaStreamTrackProcessorInit {
    track: MediaStreamTrack;
    maxBufferSize?: number;
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  class MediaStreamTrackProcessor<T = VideoFrame | AudioData> {
    constructor(init: MediaStreamTrackProcessorInit);
    readonly readable: ReadableStream<T>;
  }
}
