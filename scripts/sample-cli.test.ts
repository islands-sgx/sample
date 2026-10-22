import { describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { validateRunnerLibraryPath } from "./sample";

const cli = join(import.meta.dir, "sample.ts");

type Result = { exitCode: number; stderr: string; stdout: string };
function invoke(args: string[], extraEnv: Record<string, string> = {}): Result {
  const result = Bun.spawnSync({
    cmd: [process.execPath, cli, ...args],
    cwd: join(import.meta.dir, ".."),
    env: { ...process.env, ATFIELD_SAMPLE_SHELL: "", ...extraEnv },
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: result.exitCode ?? 1,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

describe("sample CLI rejects invalid requests before entering Nix", () => {
  test.each([
    { args: ["build", "other", "yescrypt", "raw"], message: "GROUP must be anchor or real" },
    { args: ["build", "anchor", "yescrypt", "invalid"], message: "MODE must be raw, anchor, or protect" },
    { args: ["build", "anchor", "yescrypt", "protect"], message: "anchor demonstrations have no Field or protect mode" },
    { args: ["build", "anchor", "Bad_Name", "raw"], message: "NAME must use lower-case words separated by hyphens" },
    { args: ["build", "anchor", "not-a-sample", "raw"], message: "unknown anchor sample: not-a-sample" },
    { args: ["build", "real", "sqlite", "raw"], message: "unknown real sample: sqlite" },
    { args: ["build", "bench", "sqlite", "raw"], message: "unknown bench sample: sqlite" },
  ])("rejects $args", ({ args, message }) => {
    const result = invoke(args);
    expect(result.exitCode).toBe(64);
    expect(result.stderr).toContain(message);
  });

  test("requires exact build arguments", () => {
    const result = invoke(["build", "anchor", "yescrypt", "raw", "extra"]);
    expect(result.exitCode).toBe(64);
    expect(result.stderr).toContain("usage:");
  });

  test("anchor run rejects host arguments", () => {
    const result = invoke(["run", "anchor", "yescrypt", "raw", "--help"]);
    expect(result.exitCode).toBe(64);
    expect(result.stderr).toContain("anchor samples do not accept host arguments");
  });

  test.each([
    { env: { ATFIELD_HOST_RUNNER: "maybe" }, message: "ATFIELD_HOST_RUNNER must be 'on' or 'off'" },
    { env: { ATFIELD_READINESS_BACKEND: "invalid" }, message: "ATFIELD_READINESS_BACKEND must be 'kernel' or 'userspace'" },
    { env: { ATFIELD_HOST_RUNNER: "off" }, message: "requires explicit ATFIELD_READINESS_BACKEND=userspace" },
  ])("rejects protect runner configuration $env", ({ env, message }) => {
    const result = invoke(["run", "real", "ehsm", "protect"], env);
    expect(result.exitCode).toBe(64);
    expect(result.stderr).toContain(message);
  });
});

test("protect runner rejects a missing LD_LIBRARY_PATH component", () => {
  const missingDirectory = `/nix/store/sample-cli-missing-${randomUUID()}`;
  expect(() => validateRunnerLibraryPath(missingDirectory)).toThrow(
    "protect runner only accepts existing Nix store library directories in LD_LIBRARY_PATH",
  );
});
