'use client';

import { HudSessionView } from '@/components/app/hud-session-view';
import { WelcomeView } from '@/components/app/welcome-view';
import { useAgent, useSessionContext } from '@livekit/components-react';
import { AnimatePresence, motion } from 'motion/react';

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
