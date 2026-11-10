// Runs the tests Wink exported during Tests/agent_e2e.py (CI: on Linux, in
// all three engines). Tests/fixtures must be served on 127.0.0.1:8765.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '../exported-tests',
  reporter: 'list',
  timeout: 20_000,
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
});
