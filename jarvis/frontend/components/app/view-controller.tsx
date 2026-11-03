'use client';

import { HudSessionView } from '@/components/app/hud-session-view';
import { WelcomeView } from '@/components/app/welcome-view';
import { useAgent, useSessionContext } from '@livekit/components-react';
import { AnimatePresence, motion } from 'motion/react';
import { useEffect, useRef } from 'react';

const MotionWelcomeView = motion.create(WelcomeView);

const VIEW_MOTION_PROPS = {
  variants: {
    visible: { opacity: 1 },
    hidden:  { opacity: 0 },
  },
  initial: 'hidden',
  animate: 'visible',
  exit:    'hidden',
  transition: { duration: 0.5, ease: 'linear' },
};

interface ViewControllerProps {
  isVideoInputSupported: boolean;
}

export function ViewController({ isVideoInputSupported }: ViewControllerProps) {
  const { isConnected, start } = useSessionContext();
  const agent = useAgent();

  // Keep the latest `start` without retriggering the effect below.
  const startRef = useRef(start);
  useEffect(() => {
    startRef.current = start;
  }, [start]);

  // Hands-free operation: connect on its own so the user only has to speak
  // ("Jarvis") and never has to press a button. Attempted once per page load.
  const autoStartAttempted = useRef(false);
  useEffect(() => {
    if (autoStartAttempted.current) return;
    autoStartAttempted.current = true;

    const timer = window.setTimeout(() => {
      startRef.current?.().catch(() => {
        // Autoplay or microphone permission may block this; the welcome
        // screen's button stays available as a manual fallback.
      });
    }, 1600);

    return () => window.clearTimeout(timer);
  }, []);

  return (
    <AnimatePresence mode="wait">
      {!isConnected && (
        <MotionWelcomeView
          key="welcome"
          {...VIEW_MOTION_PROPS}
          startButtonText="Activate Jarvis"
          onStartCall={start}
        />
      )}

      {isConnected && (
        <motion.div
          key="session"
          {...VIEW_MOTION_PROPS}
          className="fixed inset-0"
        >
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
