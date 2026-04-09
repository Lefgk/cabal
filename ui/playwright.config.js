import { defineConfig, devices } from '@playwright/test';

// Tests run against a production build served by `vite preview`. Reads hit
// live PulseChain; writes are captured by a mocked EIP-1193 provider injected
// into `window.ethereum` (see test/e2e/fixtures/mockProvider.js).
const PORT = 4173;
const BASE_URL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: './test/e2e',
  fullyParallel: false, // shared dev server, serial is safer + clearer logs
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: process.env.CI ? 'github' : [['list']],
  timeout: 60_000,
  expect: { timeout: 20_000 },

  use: {
    baseURL: BASE_URL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  webServer: {
    command: `npx vite preview --port ${PORT} --strictPort`,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },
});
