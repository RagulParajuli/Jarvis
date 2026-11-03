import { cn } from '@/lib/shadcn/utils';
import '@/styles/globals.css';
import localFont from 'next/font/local';

const commitMono = localFont({
  display: 'swap',
  variable: '--font-commit-mono',
  src: [
    { path: '../fonts/CommitMono-400-Regular.otf', weight: '400', style: 'normal' },
    { path: '../fonts/CommitMono-700-Regular.otf', weight: '700', style: 'normal' },
    { path: '../fonts/CommitMono-400-Italic.otf',  weight: '400', style: 'italic' },
    { path: '../fonts/CommitMono-700-Italic.otf',  weight: '700', style: 'italic' },
  ],
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="en"
      /* Always dark — Jarvis HUD is dark-only */
      className={cn(commitMono.variable, 'dark scroll-smooth antialiased')}
      suppressHydrationWarning
    >
      <head>
        <title>JARVIS</title>
        <meta name="description" content="Just A Rather Very Intelligent System" />
      </head>
      <body className="overflow-x-hidden bg-[#06090d] font-mono">
        {/* Subtle scanline overlay */}
        <div className="hud-scanlines" aria-hidden="true" />
        {children}
      </body>
    </html>
  );
}
