// Wrapper around @salutejs/jazz-sdk-web that hides plugin/init plumbing.
// Mirrors the patterns used in the official jazz-web-sdk-demo
// (AppContainer.tsx + NewClientForm.tsx + ClientCard.tsx).

import {
  createJazzClient,
  createJazzSdkWeb,
  createSdkToken,
  withAnonymousJoin,
  type JazzClient,
  type JazzRoom,
  type JazzSdk,
} from '@salutejs/jazz-sdk-web';

import {
  audioOutputMixerPlugin,
  logsPlugin,
  videoElementPoolPlugin,
} from '@salutejs/jazz-sdk-web-plugins';

export interface JazzConnectionConfig {
  /** SDK Key (base64-encoded JSON with projectId + ECDSA JWK). */
  sdkKey: string;
  /** Server URL — public salutejazz cloud or on-prem instance. */
  serverUrl: string;
  /** Stable identifier for this bridge — used as the JWT `sub` claim. */
  userId: string;
  /** Display name shown to other participants in the room. */
  userName: string;
  /** Room id. */
  roomId: string;
  /** Room password (if the room requires one). */
  password?: string;
}

export interface JazzConnection {
  sdk: JazzSdk;
  client: JazzClient;
  room: JazzRoom;
  /** Disposes the SDK + client + room and stops all worker timers. */
  dispose(): Promise<void>;
}

const log = (level: string, ...args: unknown[]) => {
  // eslint-disable-next-line no-console
  console.log(`[jazz:${level}]`, ...args);
  if (typeof window !== 'undefined' && window.mainBridge) {
    window.mainBridge.log(`jazz:${level}`, ...args);
  }
};

export async function joinRoom(cfg: JazzConnectionConfig): Promise<JazzConnection> {
  log('info', 'creating SDK', {
    serverUrl: cfg.serverUrl,
    userName: cfg.userName,
    roomId: cfg.roomId,
  });

  // 1. Create SDK process-wide instance.
  const sdk = await createJazzSdkWeb({
    clientName: 'SaluteJazzNdiBridge',
    configFlags: {
      // Allow anonymous join if the SDK Key permits it.
      'vcsSdk.canCreateAnonymousRoom': 'true',
    },
    plugins: [
      videoElementPoolPlugin(),
      audioOutputMixerPlugin(),
      logsPlugin({
        logLevel: 'info',
        isEnableStdout: true,
      }),
    ],
  });

  log('info', 'SDK created');

  // 2. Create JazzClient pointed at the SaluteJazz server. The auth provider
  // refreshes the access token automatically when the server returns 401.
  const client = await createJazzClient(sdk, {
    serverUrl: cfg.serverUrl,
    authProvider: {
      handleUnauthorizedError: async ({ loginBySdkToken }) => {
        log('warn', 'access token expired — refreshing via SDK Key');
        try {
          const { sdkToken } = await createSdkToken(cfg.sdkKey, {
            iss: 'SaluteJazzNdiBridge',
            sub: cfg.userId,
            userName: cfg.userName,
          });
          await loginBySdkToken(sdkToken);
          return 'retry';
        } catch (err) {
          log('error', 'failed to refresh auth', err);
          return 'fail';
        }
      },
    },
  });

  log('info', 'client created, validating room');

  // 3. Validate that the room exists and the password is correct before
  // attempting to join — gives a clean error path.
  await client.conferences.getDetails({
    roomId: cfg.roomId,
    password: cfg.password ?? '',
  });

  log('info', 'room details confirmed, joining');

  // 4. Join the room as an anonymous participant. We don't acquire local
  // mic/camera — this is a pure receiver. SaluteJazz still expects valid
  // device IDs, but the SDK will gracefully handle "no device".
  const room = client.conferences.join(
    {
      roomId: cfg.roomId,
      password: cfg.password ?? '',
    },
    withAnonymousJoin({ userName: cfg.userName }),
  );

  log('info', 'joined room', { roomId: cfg.roomId });

  return {
    sdk,
    client,
    room,
    async dispose() {
      try {
        room.leave?.();
      } catch (err) {
        log('warn', 'leave failed', err);
      }
      try {
        // JazzClient does not have a generic "destroy" in the public API; we
        // rely on SDK destruction below.
      } catch (err) {
        log('warn', 'client cleanup failed', err);
      }
      try {
        sdk.destroy();
      } catch (err) {
        log('warn', 'sdk destroy failed', err);
      }
    },
  };
}
