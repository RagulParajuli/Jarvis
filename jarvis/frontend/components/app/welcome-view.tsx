'use client';

import React, { useEffect, useState } from 'react';

interface WelcomeViewProps {
  startButtonText: string;
  onStartCall: () => void;
}

const BOOT_LINES = [
  'JARVIS v4.2.1 — INITIALIZING...',
  'Neural link: STANDBY',
  'Voice recognition: READY',
  'Wake word: "JARVIS"',
  'Browser interface: ACTIVE',
  'Search engine: DUCKDUCKGO',
  'Local PC access: READY',
  'All systems nominal.',
  '> Awaiting your voice...',
];

export const WelcomeView = ({
  startButtonText,
  onStartCall,
  ref,
}: React.ComponentProps<'div'> & WelcomeViewProps) => {
  const [visibleLines, setVisibleLines] = useState<number>(0);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let i = 0;
    const timer = setInterval(() => {
      i++;
      setVisibleLines(i);
      if (i >= BOOT_LINES.length) {
        clearInterval(timer);
        setTimeout(() => setReady(true), 300);
      }
    }, 220);
    return () => clearInterval(timer);
  }, []);

  return (
    <div
      ref={ref}
      className="hud-boot fixed inset-0 flex flex-col items-center justify-center hud-grid-bg"
    >
      {/* Central ring decoration */}
      <div className="relative mb-10 flex items-center justify-center">
        {/* Outer ring */}
        <div
          className="absolute rounded-full border border-[var(--hud-cyan)] opacity-20"
          style={{ width: 220, height: 220 }}
        />
        {/* Mid ring */}
        <div
          className="absolute rounded-full border border-[var(--hud-cyan)] opacity-40"
          style={{ width: 160, height: 160 }}
        />
        {/* Inner ring with spin */}
        <div
          className="absolute rounded-full border-t border-r border-[var(--hud-cyan)]"
          style={{
            width: 110,
            height: 110,
            animation: 'spin 3s linear infinite',
          }}
        />
        {/* JARVIS text */}
        <div className="flex flex-col items-center">
          <span
            className="hud-glow font-mono text-4xl font-bold tracking-[0.35em]"
            style={{ letterSpacing: '0.35em' }}
          >
            JARVIS
          </span>
          <span className="hud-label mt-1 opacity-60">PERSONAL AI SYSTEM</span>
        </div>
      </div>

      {/* Boot log terminal */}
      <div
        className="hud-panel mb-10 w-full max-w-md px-6 py-4"
        style={{ minHeight: 170 }}
      >
        <p className="hud-label mb-3 border-b border-[var(--hud-border)] pb-2">
          SYSTEM BOOT LOG
        </p>
        <div className="space-y-1">
          {BOOT_LINES.slice(0, visibleLines).map((line, i) => (
            <p
              key={i}
              className="font-mono text-xs"
              style={{
                color:
                  line.startsWith('>')
                    ? 'var(--hud-cyan)'
                    : line.includes('READY') || line.includes('ACTIVE') || line.includes('nominal')
                    ? 'var(--hud-cyan)'
                    : 'var(--hud-text-dim)',
              }}
            >
              {line}
            </p>
          ))}
          {visibleLines < BOOT_LINES.length && (
            <span
              className="inline-block h-3 w-1.5 bg-[var(--hud-cyan)]"
              style={{ animation: 'pulse 1s steps(1) infinite' }}
            />
          )}
        </div>
      </div>

      {/* Voice-first activation hint */}
      <p
        className="hud-label mb-4 text-center"
        style={{
          color: ready ? 'var(--hud-cyan)' : 'var(--hud-text-dim)',
          textShadow: ready ? '0 0 12px var(--hud-cyan-glow)' : 'none',
        }}
      >
        {ready ? 'SAY "JARVIS" TO ACTIVATE — NO BUTTON NEEDED' : 'INITIALIZING...'}
      </p>

      {/* Manual fallback in case the browser blocks the automatic connection */}
      <button
        onClick={onStartCall}
        disabled={!ready}
        className="relative overflow-hidden border border-[var(--hud-cyan)] px-12 py-3 font-mono text-xs font-bold tracking-[0.3em] uppercase transition-all duration-300 disabled:cursor-not-allowed disabled:opacity-30"
        style={{
          color: ready ? 'var(--hud-bg)' : 'var(--hud-cyan)',
          background: ready ? 'var(--hud-cyan)' : 'transparent',
          boxShadow: ready ? '0 0 20px var(--hud-cyan-glow)' : 'none',
          clipPath:
            'polygon(8px 0%, calc(100% - 8px) 0%, 100% 8px, 100% calc(100% - 8px), calc(100% - 8px) 100%, 8px 100%, 0% calc(100% - 8px), 0% 8px)',
        }}
      >
        {ready ? startButtonText.toUpperCase() : 'INITIALIZING...'}
      </button>

      {/* Bottom coordinates decoration */}
      <div className="absolute bottom-6 left-6 hud-label opacity-40">
        LAT 13.0827° N &nbsp;|&nbsp; LON 80.2707° E
      </div>
      <div className="absolute bottom-6 right-6 hud-label opacity-40">
        SYS STATUS: NOMINAL
      </div>

      <style>{`
        @keyframes spin { to { transform: rotate(360deg); } }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
      `}</style>
    </div>
  );
};
