import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  experimental: {
    // Tree-shake these large packages so unused icons/components are dropped
    // — reduces the JS bundle the browser downloads without removing features.
    optimizePackageImports: [
      '@phosphor-icons/react',
      '@radix-ui/react-collapsible',
      '@radix-ui/react-dialog',
      '@radix-ui/react-dropdown-menu',
      '@radix-ui/react-hover-card',
      '@radix-ui/react-popover',
      '@radix-ui/react-progress',
      '@radix-ui/react-scroll-area',
      '@radix-ui/react-select',
      '@radix-ui/react-separator',
      '@radix-ui/react-slot',
      '@radix-ui/react-toggle',
      '@radix-ui/react-tooltip',
      'lucide-react',
      'motion',
    ],
  },
};

export default nextConfig;
