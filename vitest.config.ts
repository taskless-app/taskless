import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    globals: false,
    // vitest 5 включает clearMocks по умолчанию; оставляем поведение 2.x (CI-158).
    clearMocks: false,
    include: ["tests/**/*.test.ts"],
  },
});
