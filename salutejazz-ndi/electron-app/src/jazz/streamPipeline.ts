// Tracks every (participantId, mediaType) tuple that exists in a JazzRoom
// and exposes it as a typed stream registry. This is the SaluteJazz analog of
// the `PerParticipantNdiRouter` in the original Jitsi plugin (see
// /home/user/jitsi-ndi-native/src/PerParticipantNdiRouter.cpp).

import {
  handleEvent,
  handleQuery,
  type JazzRoom,
  type JazzRoomMediaType,
  type JazzRoomParticipant,
  type JazzRoomParticipantId,
} from '@salutejs/jazz-sdk-web';

export type MediaKind = 'audio' | 'video' | 'displayScreen';

export interface StreamRecord {
  participantId: JazzRoomParticipantId;
  participantName: string;
  mediaType: MediaKind;
  /** Live MediaStream — may have its tracks replaced over time. */
  stream: MediaStream;
}

export interface StreamPipelineEvents {
  onAttach(record: StreamRecord): void;
  onDetach(participantId: JazzRoomParticipantId, mediaType: MediaKind): void;
  onParticipantUpdate?(participant: JazzRoomParticipant): void;
}

const KINDS: ReadonlyArray<MediaKind> = ['audio', 'video', 'displayScreen'];

interface ActiveRecord extends StreamRecord {
  unsubscribers: Array<() => void>;
}

/**
 * Subscribes to every per-participant media source in a JazzRoom and emits
 * onAttach / onDetach callbacks whenever a stream becomes available or goes
 * away (participant left, track muted server-side, etc.).
 */
export class StreamPipeline {
  private readonly active = new Map<string, ActiveRecord>();
  private readonly disposers: Array<() => void> = [];
  private disposed = false;

  constructor(
    private readonly room: JazzRoom,
    private readonly events: StreamPipelineEvents,
  ) {}

  start(): void {
    const initialParticipants = this.room.participants.get();
    for (const p of initialParticipants) {
      this.attachAllKinds(p);
    }

    this.disposers.push(
      handleEvent(this.room.event$, 'participantJoined', ({ payload }) => {
        this.attachAllKinds(payload.participant);
      }),
    );

    this.disposers.push(
      handleEvent(this.room.event$, 'participantLeft', ({ payload }) => {
        for (const kind of KINDS) {
          this.detach(payload.participant.id, kind);
        }
      }),
    );

    this.disposers.push(
      handleEvent(this.room.event$, 'participantUpdate', ({ payload }) => {
        this.events.onParticipantUpdate?.(payload.participant);
        // If display name changes we refresh attached records' label.
        for (const kind of KINDS) {
          const key = recordKey(payload.participant.id, kind);
          const rec = this.active.get(key);
          if (rec) {
            rec.participantName = payload.participant.name;
          }
        }
      }),
    );

    // addTrack and removeTrack signal that *some* media activity changed,
    // but the per-source state APIs (getParticipantMediaSource(...).stream())
    // already track stream lifetimes via signals — we re-evaluate on every
    // event so we don't miss late-joining audio after video, etc.
    this.disposers.push(
      handleEvent(this.room.event$, 'addTrack', ({ payload }) => {
        this.refresh(payload.participantId, payload.mediaType as MediaKind);
      }),
    );
    this.disposers.push(
      handleEvent(this.room.event$, 'removeTrack', ({ payload }) => {
        this.refresh(payload.participantId, payload.mediaType as MediaKind);
      }),
    );
    this.disposers.push(
      handleEvent(this.room.event$, 'trackMuteChanged', ({ payload }) => {
        // Mute changes don't toggle stream existence — we keep the NDI source
        // live and let the consumer push silence/black or pause locally.
        this.refresh(payload.participantId, payload.mediaType as MediaKind);
      }),
    );
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const u of this.disposers) {
      try { u(); } catch { /* swallow */ }
    }
    this.disposers.length = 0;

    for (const [, rec] of this.active) {
      for (const u of rec.unsubscribers) {
        try { u(); } catch { /* swallow */ }
      }
      this.events.onDetach(rec.participantId, rec.mediaType);
    }
    this.active.clear();
  }

  private attachAllKinds(p: JazzRoomParticipant): void {
    for (const kind of KINDS) {
      this.attachKind(p, kind);
    }
  }

  private attachKind(p: JazzRoomParticipant, mediaType: MediaKind): void {
    const key = recordKey(p.id, mediaType);
    if (this.active.has(key)) return;

    const sourceState = this.room.getParticipantMediaSource(
      p.id,
      mediaType as JazzRoomMediaType,
    );

    const initialStream = sourceState.stream();
    if (initialStream) {
      this.handleStreamReady(p, mediaType, initialStream);
      return;
    }

    // Stream isn't ready yet — subscribe via handleQuery so we get it when
    // the SDK has a track. handleQuery follows the same convention used by
    // the official demo (see useActiveVideoSource.ts).
    const unsub = handleQuery(sourceState.stream, (s: MediaStream | undefined) => {
      if (s) this.handleStreamReady(p, mediaType, s);
    });

    // Insert a placeholder so attachKind doesn't double-subscribe; refresh()
    // and handleStreamReady() will fill in the real stream when it appears.
    this.active.set(key, {
      participantId: p.id,
      participantName: p.name,
      mediaType,
      stream: new MediaStream(),
      unsubscribers: [unsub],
    });
  }

  private handleStreamReady(
    p: JazzRoomParticipant,
    mediaType: MediaKind,
    stream: MediaStream,
  ): void {
    const key = recordKey(p.id, mediaType);
    const existing = this.active.get(key);
    if (existing && existing.stream === stream) return;

    if (existing) {
      // Replace the placeholder stream; keep unsubscribers but emit detach
      // so consumers can rebuild their pipelines on the new stream.
      this.events.onDetach(p.id, mediaType);
      existing.stream = stream;
    } else {
      this.active.set(key, {
        participantId: p.id,
        participantName: p.name,
        mediaType,
        stream,
        unsubscribers: [],
      });
    }

    this.events.onAttach({
      participantId: p.id,
      participantName: p.name,
      mediaType,
      stream,
    });
  }

  private detach(participantId: JazzRoomParticipantId, mediaType: MediaKind): void {
    const key = recordKey(participantId, mediaType);
    const rec = this.active.get(key);
    if (!rec) return;
    for (const u of rec.unsubscribers) {
      try { u(); } catch { /* swallow */ }
    }
    this.active.delete(key);
    this.events.onDetach(participantId, mediaType);
  }

  private refresh(
    participantId: JazzRoomParticipantId,
    mediaType: MediaKind,
  ): void {
    const sourceState = this.room.getParticipantMediaSource(
      participantId,
      mediaType as JazzRoomMediaType,
    );
    const stream = sourceState.stream();
    const key = recordKey(participantId, mediaType);
    const existing = this.active.get(key);

    if (!stream) {
      if (existing) this.detach(participantId, mediaType);
      return;
    }

    if (!existing || existing.stream !== stream) {
      // Find participant name from the current participants list.
      const p = this.room.participants.get().find((x) => x.id === participantId);
      if (!p) return;
      this.handleStreamReady(p, mediaType, stream);
    }
  }
}

function recordKey(id: JazzRoomParticipantId, kind: MediaKind): string {
  return `${id}::${kind}`;
}
