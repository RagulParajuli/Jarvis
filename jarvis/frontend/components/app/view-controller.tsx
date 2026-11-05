'use client';

import { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { useAgent, useSessionContext } from '@livekit/components-react';
import { HudSessionView } from '@/components/app/hud-session-view';
import { WelcomeView } from '@/components/app/welcome-view';

const MotionWelcomeView = motion.create(WelcomeView);

const VIEW_MOTION_PROPS = {
  variants: {
    visible: { opacity: 1 },
    hidden: { opacity: 0 },
  },
  initial: 'hidden',
  animate: 'visible',
  exit: 'hidden',
  transition: { duration: 0.5, ease: 'linear' },
};

interface ViewControllerProps {
  isVideoInputSupported: boolean;
  accessCode: string;
  onAccessCodeChange: (value: string) => void;
}

export function ViewController({
  isVideoInputSupported,
  accessCode,
  onAccessCodeChange,
}: ViewControllerProps) {
  const { isConnected, start } = useSessionContext();
  const agent = useAgent();
  const [connectionError, setConnectionError] = useState('');
  const autoStartAttempted = useRef(false);

  const startCall = async () => {
    autoStartAttempted.current = true;
    setConnectionError('');
    try {
      await start();
    } catch (error) {
      setConnectionError(error instanceof Error ? error.message : 'Unable to connect to Jarvis.');
    }
  };

  // Keep the latest `start` without retriggering the effect below.
  const startRef = useRef(start);
  useEffect(() => {
    startRef.current = start;
  }, [start]);

  // Hands-free operation: connect on its own so the user only has to speak
  // ("Jarvis") and never has to press a button. Attempted once per page load.
  useEffect(() => {
    if (autoStartAttempted.current || !accessCode.trim()) return;

    const timer = window.setTimeout(() => {
      if (autoStartAttempted.current) return;
      autoStartAttempted.current = true;
      startRef.current?.().catch((error: unknown) => {
        setConnectionError(error instanceof Error ? error.message : 'Unable to connect to Jarvis.');
      });
    }, 1600);

    return () => window.clearTimeout(timer);
  }, [accessCode]);

  return (
    <AnimatePresence mode="wait">
      {!isConnected && (
        <MotionWelcomeView
          key="welcome"
          {...VIEW_MOTION_PROPS}
          startButtonText="Activate Jarvis"
          onStartCall={startCall}
          accessCode={accessCode}
          onAccessCodeChange={onAccessCodeChange}
          connectionError={connectionError}
        />
      )}

      {isConnected && (
        <motion.div key="session" {...VIEW_MOTION_PROPS} className="fixed inset-0">
          <HudSessionView
            preConnectMessage={
              agent.isConnected ? 'JARVIS IS LISTENING' : 'ESTABLISHING NEURAL LINK...'
            }
            supportsVideoInput={isVideoInputSupported}
            supportsScreenShare={isVideoInputSupported}
          />
        </motion.div>
      )}
    </AnimatePresence>
  );
}
