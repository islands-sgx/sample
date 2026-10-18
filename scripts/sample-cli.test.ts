import { validateMode } from "./anchor-report.ts";
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dir, "..");
const tempRoot = mkdtempSync(join(tmpdir(), "sample-cli-"));
const fakeBin = join(tempRoot, "bin");
const capture = join(tempRoot, "nix-argv.bin");

mkdirSync(fakeBin);
writeFileSync(
  join(fakeBin, "nix"),
  '#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$CAPTURE"\nexit 99\n',
);
chmodSync(join(fakeBin, "nix"), 0o755);
const env = {
  ...process.env,
  PATH: `${fakeBin}:${process.env.PATH}`,
  CAPTURE: capture,
};

afterAll(() => {
  rmSync(tempRoot, { recursive: true, force: true });
});

function run(script: string, args: string[], inputEnv = env) {
  if (existsSync(capture)) rmSync(capture);
  return spawnSync("bash", [resolve(root, "scripts", script), ...args], {
    cwd: tempRoot,
    encoding: "utf8",
    env: inputEnv,
  });
}

function reject(script: string, args: string[], pattern: RegExp) {
  const result = run(script, args);
  expect(result.status).toBe(64);
  expect(result.stderr).toMatch(pattern);
  expect(existsSync(capture)).toBe(false);
}

test("shared CLI rejects invalid selectors before entering Nix", () => {
  reject("build-sample.sh", ["bench", "sqlite", "raw"], /GROUP must be anchor or real/);
  reject("build-sample.sh", ["anchor", "sqlite", "bench"], /MODE must be raw or anchor/);
  reject("build-sample.sh", ["anchor", "../sqlite", "raw"], /NAME must use lower-case words/);
  reject("run-sample.sh", ["anchor", "not/a/sample", "raw"], /NAME must use lower-case words/);
  reject("run-sample.sh", ["anchor", "missing", "raw"], /unknown anchor sample: missing/);
});

test("build and run reject missing arguments before entering Nix", () => {
  reject("build-sample.sh", ["real", "sgxwallet"], /usage: build-sample\.sh GROUP NAME MODE/);
  reject("run-sample.sh", ["real", "sgxwallet"], /usage: run-sample\.sh GROUP NAME MODE/);
});

test("run rejects alternate anchor image arguments before a build", () => {
  reject("run-sample.sh", ["anchor", "sqlite", "raw", "alternate-enclave.so"],
    /anchor samples do not accept host arguments/);
});

test("sample_setup accepts a valid sample", () => {
  const result = spawnSync("bash", ["-c",
    `source ${JSON.stringify(resolve(root, "scripts/sample.sh"))}; sample_setup real sgxwallet anchor`],
    { cwd: tempRoot, encoding: "utf8", env });
  expect(result.status).toBe(0);
  expect(result.stderr).toBe("");
});

test("sample_enter_shell preserves Nix arguments and skips a matching shell", () => {
  const script = resolve(root, "scripts/sample.sh");
  const command = `
    source ${JSON.stringify(script)};
    sample_setup real sgxwallet anchor;
    ATFIELD_SAMPLE_SHELL=$sample_marker;
    sample_enter_shell /test/entry real sgxwallet anchor 'arg with spaces'
  `;
  const matching = spawnSync("bash", ["-c", command],
    { cwd: tempRoot, encoding: "utf8", env });
  expect(matching.status).toBe(0);
  expect(existsSync(capture)).toBe(false);

  const mismatching = spawnSync("bash", ["-c", `
    source ${JSON.stringify(script)};
    sample_setup real sgxwallet anchor;
    ATFIELD_SAMPLE_SHELL=real/sgxwallet/raw;
    sample_enter_shell /test/entry real sgxwallet anchor 'arg with spaces'
  `], { cwd: tempRoot, encoding: "utf8", env });
  expect(mismatching.status).toBe(99);
  const argv = readFileSync(capture).toString("utf8").split("\0");
  argv.pop();
  expect(argv).toEqual([
    "develop",
    "--no-write-lock-file",
    `${root}#real-sgxwallet-anchor`,
    "--command",
    "env",
    "ATFIELD_SAMPLE_SHELL=real/sgxwallet/anchor",
    "bash",
    "/test/entry",
    "real",
    "sgxwallet",
    "anchor",
    "arg with spaces",
  ]);
});

test("anchor-report validateMode enforces anchor coverage and raw baseline", () => {
  expect(() =>
    validateMode("anchor/sqlite", "raw", {
      pagesWithoutC3Candidate: ["0x1000"],
      pagesWithoutNamedAnchor: ["0x1000"],
      namedNaturalAnchors: 0,
      namedConstructedAnchors: 0,
    }),
  ).not.toThrow();

  expect(() =>
    validateMode("anchor/sqlite", "raw", {
      pagesWithoutC3Candidate: [],
      pagesWithoutNamedAnchor: [],
      namedNaturalAnchors: 1,
      namedConstructedAnchors: 0,
    }),
  ).toThrow(/unexpected named ATField anchors in raw baseline/);

  expect(() =>
    validateMode("anchor/sqlite", "anchor", {
      pagesWithoutC3Candidate: ["0x1000"],
      pagesWithoutNamedAnchor: [],
      namedNaturalAnchors: 10,
      namedConstructedAnchors: 1,
    }),
  ).toThrow(/executable pages missing stable C3 candidate: 0x1000/);

  expect(() =>
    validateMode("anchor/sqlite", "anchor", {
      pagesWithoutC3Candidate: [],
      pagesWithoutNamedAnchor: ["0x2000"],
      namedNaturalAnchors: 10,
      namedConstructedAnchors: 1,
    }),
  ).toThrow(/executable pages missing named anchor symbol: 0x2000/);

  expect(() =>
    validateMode("anchor/sqlite", "anchor", {
      pagesWithoutC3Candidate: [],
      pagesWithoutNamedAnchor: [],
      namedNaturalAnchors: 10,
      namedConstructedAnchors: 1,
    }),
  ).not.toThrow();
});
