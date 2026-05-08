// SCA-82 — Vitest configuration for the ops SPA test harness.
// Mirrors vite.config.ts behavior; jsdom for React Testing Library.

import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    css: false,
    // Tests live alongside the code they exercise (`__tests__` folders).
    include: ['src/**/__tests__/*.test.{ts,tsx}'],
  },
});
