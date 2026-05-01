import { app, BrowserWindow, ipcMain } from 'electron';
import * as path from 'path';

const isHeadless = process.argv.includes('--headless');

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1100,
    height: 760,
    show: !isHeadless,
    backgroundColor: '#0d111c',
    webPreferences: {
      // We deliberately enable nodeIntegration in the renderer so the
      // SaluteJazz SDK and the native NDI bridge can both load there.
      // This is an operator tool, not a browser for the open web — only the
      // application's own code runs here.
      nodeIntegration: true,
      contextIsolation: false,
      sandbox: false,
      // Permissions used by getUserMedia / display capture even though we
      // don't *need* the local mic/camera — when the SDK probes devices
      // it must not error out.
      webSecurity: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  if (!isHeadless) {
    win.webContents.openDevTools({ mode: 'detach' });
  }

  return win;
}

app.whenReady().then(() => {
  createWindow();

  // We don't need a real microphone for headless NDI publishing, but Chromium
  // will still ask for permission when the SDK enumerates devices. Auto-deny
  // is fine — getUserMedia just yields no streams, and we never join with mic.
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// Bridge log messages from renderer to main stdout (for headless runs).
ipcMain.on('log', (_evt, level: string, ...args: unknown[]) => {
  const tag = `[renderer:${level}]`;
  // eslint-disable-next-line no-console
  console.log(tag, ...args);
});
