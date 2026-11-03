'use client';

import React, { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { useAgent, useSessionContext, useSessionMessages, useVoiceAssistant } from '@livekit/components-react';
import { AgentChatTranscript } from '@/components/agents-ui/agent-chat-transcript';
import { AgentControlBar } from '@/components/agents-ui/agent-control-bar';
import { AgentAudioVisualizerRadial } from '@/components/agents-ui/agent-audio-visualizer-radial';
import { useTranscriptToggle } from '@/hooks/useTranscriptToggle';

interface HudSessionViewProps {
  preConnectMessage?: string;
  supportsVideoInput?: boolean;
  supportsScreenShare?: boolean;
}

/** Small HUD corner-bracket decoration */
function CornerBrackets() {
  const style = 'absolute w-3 h-3 border-[var(--hud-cyan)] opacity-60';
  return (
    <>
      <span className={`${style} top-2 left-2 border-t border-l`} />
      <span className={`${style} top-2 right-2 border-t border-r`} />
      <span className={`${style} bottom-2 left-2 border-b border-l`} />
      <span className={`${style} bottom-2 right-2 border-b border-r`} />
    </>
  );
}

/** Transcript opt-in prompt overlay */
function TranscriptPrompt({
  onAccept,
  onDecline,
}: {
  onAccept: () => void;
  onDecline: () => void;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: -12 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -12 }}
      transition={{ duration: 0.3 }}
      className="absolute top-20 left-1/2 z-50 -translate-x-1/2"
    >
      <div className="hud-panel relative flex flex-col items-center gap-4 px-8 py-5 text-center">
        <CornerBrackets />
        <p className="hud-label text-[var(--hud-cyan)]">DISPLAY TRANSCRIPT?</p>
        <p className="font-mono text-xs text-[var(--hud-text-dim)] max-w-xs">
          Show live conversation text on screen?
        </p>
        <div className="flex gap-4">
          <button
            onClick={onAccept}
            className="border border-[var(--hud-cyan)] px-6 py-1.5 font-mono text-xs font-bold tracking-widest text-[var(--hud-cyan)] uppercase transition-all hover:bg-[var(--hud-cyan)] hover:text-[var(--hud-bg)]"
            style={{
              clipPath: 'polygon(6px 0%,100% 0%,100% calc(100% - 6px),calc(100% - 6px) 100%,0% 100%,0% 6px)',
            }}
          >
            YES
          </button>
          <button
            onClick={onDecline}
            className="border border-[var(--hud-text-dim)] px-6 py-1.5 font-mono text-xs font-bold tracking-widest text-[var(--hud-text-dim)] uppercase transition-all hover:border-[var(--hud-amber)] hover:text-[var(--hud-amber)]"
            style={{
              clipPath: 'polygon(6px 0%,100% 0%,100% calc(100% - 6px),calc(100% - 6px) 100%,0% 100%,0% 6px)',
            }}
          >
            NO
          </button>
        </div>
      </div>
    </motion.div>
  );
}

export function HudSessionView({
  preConnectMessage = 'JARVIS IS LISTENING',
  supportsVideoInput = false,
  supportsScreenShare = false,
}: HudSessionViewProps) {
  const session = useSessionContext();
  const { messages } = useSessionMessages(session);
  const { state: agentState } = useAgent();
  const { state: voiceState, audioTrack } = useVoiceAssistant();
  const [isChatOpen, setIsChatOpen] = useState(false);
  const scrollAreaRef = useRef<HTMLDivElement>(null);

  const { showTranscript, isPending, acceptTranscript, declineTranscript, toggleTranscript } =
    useTranscriptToggle(session.isConnected);

  // Sync isChatOpen with transcript preference
  useEffect(() => {
    setIsChatOpen(showTranscript);
  }, [showTranscript]);

  useEffect(() => {
    const lastMessage = messages.at(-1);
    if (scrollAreaRef.current && lastMessage?.from?.isLocal) {
      scrollAreaRef.current.scrollTop = scrollAreaRef.current.scrollHeight;
    }
  }, [messages]);

  const isThinking =
    voiceState === 'thinking' || voiceState === 'speaking' || agentState === 'thinking';

  return (
    <section className="relative h-full w-full overflow-hidden bg-[var(--hud-bg)] hud-grid-bg">

      {/* ── Transcript opt-in prompt ── */}
      <AnimatePresence>
        {isPending && (
          <TranscriptPrompt onAccept={acceptTranscript} onDecline={declineTranscript} />
        )}
      </AnimatePresence>

      {/* ── Transcript panel ── */}
      <AnimatePresence>
        {isChatOpen && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.3 }}
            className="absolute inset-x-0 top-0 bottom-[150px] overflow-hidden md:bottom-[180px]"
          >
            <div className="hud-transcript absolute inset-x-0 top-0 bottom-0">
              <AgentChatTranscript
                agentState={agentState}
                messages={messages}
                className="mx-auto max-w-2xl **:data-[slot=message-scroller-content]:p-4 **:data-[slot=message-scroller-content]:pt-16! md:**:data-[slot=message-scroller-content]:p-6"
              />
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── Central radial visualizer ── */}
      <AnimatePresence>
        {!isChatOpen && (
          <motion.div
            initial={{ opacity: 0, scale: 0.85 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.85 }}
            transition={{ duration: 0.5, ease: 'easeOut' }}
            className="absolute inset-0 flex flex-col items-center justify-center"
          >
            {/* Status label above visualizer */}
            <p
              className="hud-label mb-6 transition-colors duration-500"
              style={{
                color: isThinking ? 'var(--hud-cyan)' : 'var(--hud-text-dim)',
                textShadow: isThinking ? '0 0 12px var(--hud-cyan-glow)' : 'none',
              }}
            >
              {messages.length === 0 ? preConnectMessage : agentState?.toUpperCase() ?? 'LISTENING'}
            </p>

            {/* Radial ring visualizer */}
            <div className="relative">
              {/* Outer decorative ring */}
              <div
                className="pointer-events-none absolute inset-0 m-auto rounded-full border border-[var(--hud-cyan)] opacity-10"
                style={{ width: 320, height: 320, top: '50%', left: '50%', transform: 'translate(-50%,-50%)' }}
              />
              <AgentAudioVisualizerRadial
                size="xl"
                state={voiceState}
                color="#00e5ff"
                audioTrack={audioTrack}
                radius={110}
                barCount={32}
                className="size-[280px] md:size-[340px]"
              />
            </div>

            {/* JARVIS label below */}
            <p className="hud-glow mt-6 font-mono text-lg font-bold tracking-[0.4em]">JARVIS</p>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── Top-right HUD decorations ── */}
      <div className="absolute top-4 right-6 flex flex-col items-end gap-1 pointer-events-none">
        <p className="hud-label opacity-40">NEURAL LINK ACTIVE</p>
        <p className="hud-label opacity-25">ARC REACTOR: STABLE</p>
      </div>

      {/* ── Top-left system label ── */}
      <div className="absolute top-4 left-6 flex flex-col gap-1 pointer-events-none">
        <p className="hud-label opacity-40">JARVIS v4.2.1</p>
        <p className="hud-label opacity-25">STARK INDUSTRIES</p>
      </div>

      {/* ── Transcript toggle button (shown after preference is set) ── */}
      {!isPending && (
        <button
          onClick={toggleTranscript}
          title={showTranscript ? 'Hide transcript' : 'Show transcript'}
          className="absolute top-4 left-1/2 -translate-x-1/2 border border-[var(--hud-border)] px-4 py-1 font-mono text-[10px] tracking-widest uppercase transition-all hover:border-[var(--hud-cyan)] hover:text-[var(--hud-cyan)]"
          style={{
            color: showTranscript ? 'var(--hud-cyan)' : 'var(--hud-text-dim)',
            borderColor: showTranscript ? 'var(--hud-cyan)' : undefined,
            clipPath: 'polygon(5px 0%,100% 0%,100% calc(100% - 5px),calc(100% - 5px) 100%,0% 100%,0% 5px)',
          }}
        >
          {showTranscript ? '◼ TRANSCRIPT ON' : '◻ TRANSCRIPT OFF'}
        </button>
      )}

      {/* ── Bottom control bar ── */}
      <motion.div
        initial={{ opacity: 0, y: 40 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.4, delay: 0.5 }}
        className="absolute inset-x-3 bottom-0 z-50 md:inset-x-12"
      >
        {/* Pre-connect shimmer */}
        <AnimatePresence>
          {messages.length === 0 && (
            <motion.p
              key="pre-connect"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ delay: 0.8, duration: 0.5 }}
              className="shimmer shimmer-duration-2000 pointer-events-none mx-auto mb-3 block w-full max-w-2xl text-center text-xs font-bold"
            >
              {preConnectMessage}
            </motion.p>
          )}
        </AnimatePresence>

        <div className="relative mx-auto max-w-2xl pb-3 md:pb-10">
          {/* Hairline top border on control bar */}
          <div className="mb-2 h-px w-full bg-[var(--hud-border)]" />
          <AgentControlBar
            variant="livekit"
            controls={{
              leave: true,
              microphone: true,
              chat: false,          // transcript handled by our own toggle
              camera: supportsVideoInput,
              screenShare: supportsScreenShare,
            }}
            isChatOpen={false}
            isConnected={session.isConnected}
            onDisconnect={session.end}
            onIsChatOpenChange={() => {}}
          />
        </div>
      </motion.div>
    </section>
  );
}
