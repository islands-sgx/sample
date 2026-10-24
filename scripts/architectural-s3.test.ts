import { expect, test } from "bun:test";
import { assertDeclaredArchitectureS3 } from "./architectural-s3.ts";

const phase = (page_effects: unknown[]) => ({ complete: true, page_size: 4096, page_effects });
const effect = { rva: "0x2000", a: true, d: true };
const call = {
  record_type: "ecall", call_seq: 1,
  fields: [{ field_id: "field-1", phases: {
    S2_PRETOUCH: phase([effect]), S3_BODY: phase([effect]),
  } }],
};
const trace = JSON.stringify(call);
const summary = {
  completion: "complete", measurement_complete: true, exit_code: 0, invalid_ecall_count: 0,
  s3_body_page_observations: [{ field_id: "field-1", page_rva: "0x2000", a: true, d: true }],
  final_v2_validation: { verdict: "FAIL", observed_page_count: 1, final_v2_verification_failure_count: 0 },
};
const declaration = {
  schema: "atfield-architectural-s3-v1",
  signed_measurement_final_elf_sha256: "final-digest",
  effects: [{ field_id: "field-1", page_rva: "0x2000", a: true, d: true, instruction: "EGETKEY" }],
};

test("declared ENCLU page remains raw S3 and is eligible only after same-call S2", () => {
  expect(assertDeclaredArchitectureS3(summary, trace, declaration, "final-digest")).toBe(1);
  expect(summary.final_v2_validation.verdict).toBe("FAIL");
  expect(summary.s3_body_page_observations).toHaveLength(1);
});

test("an extra page, missing S2, stale Final, or another measurement failure blocks eligibility", () => {
  const extra = { ...call, fields: [{ field_id: "field-1", phases: {
    S2_PRETOUCH: phase([effect]), S3_BODY: phase([effect, { rva: "0x3000", a: true, d: true }]),
  } }] };
  expect(() => assertDeclaredArchitectureS3(summary, JSON.stringify(extra), declaration, "final-digest")).toThrow("undeclared");
  const noS2 = { ...call, fields: [{ field_id: "field-1", phases: {
    S2_PRETOUCH: phase([]), S3_BODY: phase([effect]),
  } }] };
  expect(() => assertDeclaredArchitectureS3(summary, JSON.stringify(noS2), declaration, "final-digest")).toThrow("not made ready");
  expect(() => assertDeclaredArchitectureS3(summary, trace, declaration, "other-final")).toThrow("another Final");
  const invalid = { ...summary, invalid_ecall_count: 1 };
  expect(() => assertDeclaredArchitectureS3(invalid, trace, declaration, "final-digest")).toThrow("another Final failure");
});
