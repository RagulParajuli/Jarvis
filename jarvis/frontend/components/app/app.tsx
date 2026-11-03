'use client';

import { AgentSessionProvider } from '@/components/agents-ui/agent-session-provider';
import { StartAudioButton } from '@/components/agents-ui/start-audio-button';
import { ViewController } from '@/components/app/view-controller';
import { Toaster } from '@/components/ui/sonner';
import { useAgentErrors } from '@/hooks/useAgentErrors';
import { useDebugMode } from '@/hooks/useDebug';
import { useSession } from '@livekit/components-react';
import { WarningIcon } from '@phosphor-icons/react/dist/ssr';
import { TokenSource } from 'livekit-client';
import { useMemo } from 'react';

const IN_DEVELOPMENT = process.env.NODE_ENV !== 'production';

function AppSetup() {
  useDebugMode({ enabled: IN_DEVELOPMENT });
  useAgentErrors();
  return null;
}

interface AppProps {
  tokenServerId?: string;
  tokenEndpoint: string;
  agentName?: string;
  isVideoInputSupported: boolean;
}

export function App({ tokenServerId, tokenEndpoint, agentName, isVideoInputSupported }: AppProps) {
  const tokenSource = useMemo(
    () =>
      tokenServerId
        ? TokenSource.developmentTokenServer(tokenServerId)
        : TokenSource.endpoint(tokenEndpoint),
    [tokenServerId, tokenEndpoint],
  );

  const session = useSession(tokenSource, agentName ? { agentName } : undefined);

  return (
    <AgentSessionProvider session={session}>
      <AppSetup />
      <main className="grid h-svh grid-cols-1 place-content-center">
        <ViewController isVideoInputSupported={isVideoInputSupported} />
      </main>
      <StartAudioButton label="Start Audio" />
      <Toaster
        icons={{ warning: <WarningIcon weight="bold" /> }}
        position="top-center"
        className="toaster group"
        style={
          {
            '--normal-bg':     'var(--hud-surface)',
            '--normal-text':   'var(--hud-text)',
            '--normal-border': 'var(--hud-border)',
          } as React.CSSProperties
        }
      />
    </AgentSessionProvider>
  );
}
