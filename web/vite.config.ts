/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// In development the API runs on `npm run dev -w api` (port 8787); the proxy keeps requests same-origin.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { "/v1": "http://localhost:8787" } },
  // testTimeout leaves room for a 5 s async wait (src/test/setup.ts) to fail with its own error.
  test: { environment: "jsdom", globals: true, setupFiles: ["./src/test/setup.ts"], testTimeout: 15000 },
});
