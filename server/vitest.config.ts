import { defineConfig } from "vitest/config";

const TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL ?? "postgres://shelfcase:shelfcase@localhost:55432/shelfcase_test";

export default defineConfig({
  test: {
    globals: false,
    environment: "node",
    include: ["test/**/*.test.ts"],
    globalSetup: ["./test/global-setup.ts"],
    // One shared PostgreSQL database means test files must not interleave.
    fileParallelism: false,
    hookTimeout: 30_000,
    testTimeout: 30_000,
    env: {
      NODE_ENV: "test",
      DATABASE_URL: TEST_DATABASE_URL,
      LOG_LEVEL: "silent",
      TELEMETRY_FILE: "./var/telemetry.test.jsonl",
    },
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary", "html"],
      reportsDirectory: "./coverage",
      include: ["src/**/*.ts"],
      exclude: ["src/server.ts", "src/migrate-cli.ts", "src/**/*.d.ts"],
      thresholds: {
        // Measured in Step 6; keep the bar where the suite actually stands.
        lines: 80,
        statements: 80,
        functions: 70,
        branches: 65,
      },
    },
  },
});
