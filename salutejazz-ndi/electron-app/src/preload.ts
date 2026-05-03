// Minimal preload — most of the heavy lifting is in the renderer because we
// need direct access to MediaStreamTrackProcessor (a renderer-only API).
// We expose a tiny stdout-logging shim for headless runs.

import { ipcRenderer } from 'electron';

window.mainBridge = {
  log: (level: string, ...args: unknown[]) => ipcRenderer.send('log', level, ...args),
};
