import { join } from "node:path";

export type SampleGroup = "anchor" | "bench/micro" | "bench/application";
export type SampleMode = "raw" | "anchor" | "protect" | "protect-naive";

export function sampleBuildDir(root: string, group: SampleGroup, name: string, mode: SampleMode): string {
  return join(root, "build", group, name, mode);
}

export function sampleAcquireDir(root: string, group: SampleGroup, name: string, mode: SampleMode): string {
  return join(root, "build", "acquire", group, name, mode);
}

export function sampleWorksetPath(root: string, group: SampleGroup, name: string, mode: SampleMode): string {
  return join(sampleAcquireDir(root, group, name, mode), "workset.dynamic.v2.json");
}

export function sampleCorpusPath(root: string, group: SampleGroup, name: string, mode: SampleMode): string {
  return join(sampleAcquireDir(root, group, name, mode), "corpus");
}
