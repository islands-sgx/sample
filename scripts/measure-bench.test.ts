import { expect, test } from "bun:test";
import { validateFinalV2Batch } from "./measure-bench.ts";

const identity = {
  manifestSha256: "manifest",
  worksetSha256: "workset",
  capacityQ: 12288,
  signedFinalElfSha256: "production-final",
  readyTableSha256: "ready-table",
  signedMeasurementFinalElfSha256: "measurement-final",
  manifestFieldCount: 2,
  productionConfigSha256: "production-config",
  measurementConfigSha256: "measurement-config",
};

function execution(fields: string[], changes: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    target_kind: "final-v2",
    completion: "complete",
    measurement_complete: true,
    exit_code: 0,
    timed_out: false,
    valid_ecall_count: 2,
    invalid_ecall_count: 0,
    selected_enclave_sha256: identity.signedMeasurementFinalElfSha256,
    final_v2_validation: {
      verdict: "PASS",
      observed_page_count: 0,
      final_v2_verification_failure_count: 0,
      measured_field_ids: fields,
      final_v2_target: {
        manifestSha256: identity.manifestSha256,
        worksetSha256: identity.worksetSha256,
        capacityQ: identity.capacityQ,
        signedFinalElfSha256: identity.signedFinalElfSha256,
        readyTableSha256: identity.readyTableSha256,
        signedMeasurementFinalElfSha256: identity.signedMeasurementFinalElfSha256,
        manifestFieldCount: identity.manifestFieldCount,
        productionConfigSha256: identity.productionConfigSha256,
        measurementConfigSha256: identity.measurementConfigSha256,
      },
    },
    ...changes,
  };
}

test("Final v2 batch aggregates target Field coverage across fresh executions", () => {
  expect(() => validateFinalV2Batch(
    ["field-a", "field-b"],
    [execution(["field-a"]), execution(["field-b"])],
    identity,
  )).not.toThrow();
});

test("Final v2 batch rejects missing target Fields", () => {
  expect(() => validateFinalV2Batch(["field-a", "field-b"], [execution(["field-a"])], identity))
    .toThrow("did not enter every target Field: field-b");
});

test("Final v2 batch rejects raw S3 observations and identity drift", () => {
  const withS3 = execution(["field-a", "field-b"]);
  (withS3.final_v2_validation as Record<string, unknown>).observed_page_count = 1;
  expect(() => validateFinalV2Batch(["field-a", "field-b"], [withS3], identity))
    .toThrow("raw S3/AEX/measurement/readiness/SGX verification");
  const withIdentityDrift = execution(["field-a", "field-b"]);
  (((withIdentityDrift.final_v2_validation as Record<string, unknown>).final_v2_target as Record<string, unknown>))
    .readyTableSha256 = "other-ready-table";
  expect(() => validateFinalV2Batch(["field-a", "field-b"], [withIdentityDrift], identity))
    .toThrow("different frozen Final/ReadyTable identity");
});

test("Final v2 batch rejects unexpected AEX/measurement/readiness/SGX diagnostics", () => {
  const failed = execution(["field-a", "field-b"]);
  (failed.final_v2_validation as Record<string, unknown>).final_v2_verification_failure_count = 1;
  expect(() => validateFinalV2Batch(["field-a", "field-b"], [failed], identity))
    .toThrow("raw S3/AEX/measurement/readiness/SGX verification");
});

test("Final v2 batch rejects failed business execution even if trace is clean", () => {
  expect(() => validateFinalV2Batch(
    ["field-a", "field-b"],
    [execution(["field-a", "field-b"], { exit_code: 1 })],
    identity,
  )).toThrow("did not complete successfully");
});

test("Final v2 batch keeps strict FAIL while allowing a declared architectural page for timing", () => {
  const withS3 = execution(["field-a", "field-b"], {
    s3_body_page_observations: [{ field_id: "field-a", page_rva: "0x2000", a: true, d: true }],
  });
  Object.assign(withS3.final_v2_validation as Record<string, unknown>, { verdict: "FAIL", observed_page_count: 1 });
  const effect = { rva: "0x2000", a: true, d: true };
  const phase = (page_effects: unknown[]) => ({ complete: true, page_size: 4096, page_effects });
  const traceText = JSON.stringify({ record_type: "ecall", fields: [
    { field_id: "field-a", phases: { S2_PRETOUCH: phase([effect]), S3_BODY: phase([effect]) } },
  ] });
  const declaration = {
    schema: "atfield-architectural-s3-v1",
    signed_measurement_final_elf_sha256: identity.signedMeasurementFinalElfSha256,
    effects: [{ field_id: "field-a", page_rva: "0x2000", a: true, d: true, instruction: "EGETKEY" }],
  };
  const replay = new Map([[0, { declaration, traceText }]]);
  expect(validateFinalV2Batch(["field-a", "field-b"], [withS3], identity, replay)).toBe(1);
  expect((withS3.final_v2_validation as Record<string, unknown>).verdict).toBe("FAIL");
  expect(() => validateFinalV2Batch(["field-a", "field-b"], [withS3], identity))
    .toThrow("raw S3/AEX/measurement/readiness/SGX verification");
});
