// Top-level orchestration for the renderer process. Wires UI ↔ Jazz SDK ↔ NDI.

import { joinRoom, type JazzConnection } from './jazz/jazzClient';
import { StreamPipeline } from './jazz/streamPipeline';
import { NdiPump, type NdiPumpStats } from './jazz/ndiPipeline';

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing #${id}`);
  return el as T;
};

const ui = {
  serverUrl: $<HTMLInputElement>('serverUrl'),
  sdkKey: $<HTMLTextAreaElement>('sdkKey'),
  userName: $<HTMLInputElement>('userName'),
  userId: $<HTMLInputElement>('userId'),
  roomId: $<HTMLInputElement>('roomId'),
  password: $<HTMLInputElement>('password'),
  enableNdi: $<HTMLInputElement>('enableNdi'),
  joinBtn: $<HTMLButtonElement>('join'),
  leaveBtn: $<HTMLButtonElement>('leave'),
  status: $<HTMLDivElement>('status'),
  log: $<HTMLDivElement>('log'),
  sources: $<HTMLDivElement>('sources'),
  connStatus: $<HTMLSpanElement>('conn-status'),
};

let connection: JazzConnection | null = null;
let pipeline: StreamPipeline | null = null;
const pumps = new Map<string, NdiPump>();
const sourceCards = new Map<string, HTMLDivElement>();

const recordKey = (pid: string, kind: string) => `${pid}::${kind}`;

function appendLog(level: 'info' | 'warn' | 'error' | 'stream', ...args: unknown[]): void {
  const row = document.createElement('div');
  row.className = `row ${level}`;
  const ts = new Date().toISOString().substring(11, 19);
  row.textContent = `${ts} [${level}] ${args.map(formatArg).join(' ')}`;
  ui.log.appendChild(row);
  ui.log.scrollTop = ui.log.scrollHeight;
  while (ui.log.children.length > 500) {
    ui.log.removeChild(ui.log.firstChild!);
  }
  if (window.mainBridge) window.mainBridge.log(level, ...args);
}

function formatArg(v: unknown): string {
  if (v == null) return String(v);
  if (typeof v === 'string') return v;
  try { return JSON.stringify(v); } catch { return String(v); }
}

function setStatus(text: string, kind: 'ok' | 'err' | 'info' = 'info'): void {
  ui.status.innerHTML = `<span class="${kind}">${text}</span>`;
}

function addSourceCard(key: string, label: string, kind: string): void {
  const card = document.createElement('div');
  card.className = 'source-card';
  card.innerHTML = `
    <span class="name">${label}</span>
    <span class="badge ${kind}">${kind}</span>
    <span class="stats" data-key="${key}">…</span>
  `;
  ui.sources.appendChild(card);
  sourceCards.set(key, card);
}

function updateSourceStats(stats: NdiPumpStats): void {
  const key = recordKey(stats.participantId, stats.mediaType);
  const card = sourceCards.get(key);
  if (!card) return;
  const statsEl = card.querySelector('.stats') as HTMLElement;
  if (statsEl) {
    statsEl.textContent = `${stats.framesSent} fr · ${stats.fps.toFixed(1)} fps · ${stats.hasNdiSender ? 'NDI live' : 'dry-run'}`;
  }
}

function removeSourceCard(key: string): void {
  const card = sourceCards.get(key);
  if (card) {
    card.remove();
    sourceCards.delete(key);
  }
}

async function startBridge(): Promise<void> {
  ui.joinBtn.disabled = true;
  ui.leaveBtn.disabled = false;
  setStatus('подключение…', 'info');
  ui.connStatus.textContent = 'подключение…';

  const cfg = {
    sdkKey: ui.sdkKey.value.trim(),
    serverUrl: ui.serverUrl.value.trim(),
    userId: ui.userId.value.trim() || `bridge-${Date.now()}`,
    userName: ui.userName.value.trim() || 'NDI Bridge',
    roomId: ui.roomId.value.trim(),
    password: ui.password.value.trim() || undefined,
  };

  if (!cfg.sdkKey) { setStatus('SDK Key пуст', 'err'); resetUi(); return; }
  if (!cfg.roomId) { setStatus('Room ID пуст', 'err'); resetUi(); return; }

  try {
    connection = await joinRoom(cfg);
  } catch (err) {
    appendLog('error', 'join failed', (err as Error).message);
    setStatus(`Ошибка подключения: ${(err as Error).message}`, 'err');
    resetUi();
    return;
  }

  setStatus('подключено, ждём участников…', 'ok');
  ui.connStatus.textContent = `в комнате ${cfg.roomId}`;
  appendLog('info', `joined room ${cfg.roomId} as ${cfg.userName}`);

  const enableNdi = ui.enableNdi.checked;

  pipeline = new StreamPipeline(connection.room, {
    onAttach(rec) {
      const key = recordKey(rec.participantId, rec.mediaType);
      const label = `${rec.participantName} (${rec.participantId.substring(0, 6)})`;
      appendLog('stream', `+ ${rec.mediaType} from ${label}`);
      addSourceCard(key, label, rec.mediaType === 'displayScreen' ? 'display' : rec.mediaType);

      const pump = new NdiPump(rec, {
        enableNdi,
        onLog: (level, msg) => appendLog(level as 'info' | 'warn' | 'error', msg),
        onStats: (stats) => updateSourceStats(stats),
      });
      pumps.set(key, pump);
      pump.start();
    },
    onDetach(participantId, mediaType) {
      const key = recordKey(participantId, mediaType);
      appendLog('stream', `- ${mediaType} from ${participantId.substring(0, 6)}`);
      const pump = pumps.get(key);
      if (pump) {
        pump.stop().catch((e) => appendLog('warn', 'pump.stop failed', e));
        pumps.delete(key);
      }
      removeSourceCard(key);
    },
    onParticipantUpdate(p) {
      appendLog('info', `participant updated: ${p.id} → ${p.name}`);
    },
  });

  pipeline.start();
}

async function stopBridge(): Promise<void> {
  ui.leaveBtn.disabled = true;
  setStatus('выход из комнаты…', 'info');

  for (const pump of pumps.values()) {
    try { await pump.stop(); } catch (e) { appendLog('warn', 'pump.stop failed', e); }
  }
  pumps.clear();
  for (const k of [...sourceCards.keys()]) removeSourceCard(k);

  pipeline?.dispose();
  pipeline = null;

  if (connection) {
    await connection.dispose();
    connection = null;
  }

  setStatus('отключено', 'info');
  ui.connStatus.textContent = 'не подключено';
  resetUi();
}

function resetUi(): void {
  ui.joinBtn.disabled = false;
  ui.leaveBtn.disabled = true;
}

ui.joinBtn.addEventListener('click', () => {
  startBridge().catch((e) => {
    appendLog('error', 'startBridge crashed', e);
    setStatus(`Сбой: ${(e as Error).message}`, 'err');
    resetUi();
  });
});

ui.leaveBtn.addEventListener('click', () => {
  stopBridge().catch((e) => appendLog('error', 'stopBridge crashed', e));
});

window.addEventListener('beforeunload', () => {
  // Best-effort sync teardown — Electron is closing.
  for (const p of pumps.values()) p.stop().catch(() => undefined);
  connection?.dispose().catch(() => undefined);
});

appendLog('info', 'renderer ready');
