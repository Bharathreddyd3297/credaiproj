import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5174,
    strictPort: true,
    open: true,
  },
  // Unit tests (npm test): tests/*.test.jsx in a simulated browser (jsdom).
  // CI publishes the JUnit results and sends coverage/lcov.info to SonarQube.
  test: {
    environment: 'jsdom',
    include: ['tests/**/*.test.{js,jsx}'],
    reporters: ['default', ['junit', { outputFile: 'test-results.xml' }]],
    coverage: {
      provider: 'v8',
      include: ['src/**'],
      reporter: ['text-summary', 'lcov', 'cobertura'],
    },
  },
});
