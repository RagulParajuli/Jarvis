'use client';

import { useState, useCallback, useEffect, useRef } from 'react';

type TranscriptPreference = 'yes' | 'no' | 'pending';

/**
 * Manages the optional transcript display.
 *
 * On first connect it sets preference to 'pending', which triggers a prompt
 * asking the user if they want to see the transcript. Their answer is
 * remembered in sessionStorage for the current session.
 *
 * Returns:
 *  - showTranscript:  whether to render <AgentChatTranscript />
 *  - isPending:       whether the prompt should be shown
 *  - acceptTranscript: user clicked "Yes"
 *  - declineTranscript: user clicked "No"
 *  - toggleTranscript: flip the choice at any time
 */
export function useTranscriptToggle(isConnected: boolean) {
  const hasPrompted = useRef(false);

  const [preference, setPreference] = useState<TranscriptPreference>(() => {
    if (typeof window === 'undefined') return 'pending';
    const saved = sessionStorage.getItem('jarvis-transcript-pref') as TranscriptPreference | null;
    return saved ?? 'pending';
  });

  // Trigger prompt exactly once when the session connects
  useEffect(() => {
    if (isConnected && !hasPrompted.current && preference === 'pending') {
      hasPrompted.current = true;
      // Keep preference as 'pending' — the UI will render the prompt
    }
  }, [isConnected, preference]);

  const acceptTranscript = useCallback(() => {
    sessionStorage.setItem('jarvis-transcript-pref', 'yes');
    setPreference('yes');
  }, []);

  const declineTranscript = useCallback(() => {
    sessionStorage.setItem('jarvis-transcript-pref', 'no');
    setPreference('no');
  }, []);

  const toggleTranscript = useCallback(() => {
    setPreference((prev) => {
      const next = prev === 'yes' ? 'no' : 'yes';
      sessionStorage.setItem('jarvis-transcript-pref', next);
      return next;
    });
  }, []);

  return {
    showTranscript: preference === 'yes',
    isPending: isConnected && preference === 'pending',
    acceptTranscript,
    declineTranscript,
    toggleTranscript,
  };
}
