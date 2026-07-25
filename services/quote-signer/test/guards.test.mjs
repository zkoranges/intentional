// Bind safety, deployment refusal, and secret hygiene.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  RETIRED_KERNELS,
  assertBindSafe,
  assertNoSecretMaterial,
  isLoopbackHost,
  verifyDeploymentConfig,
} from "../guards.mjs";

const RETIRED_KERNEL = [...RETIRED_KERNELS][0];
const FRESH_KERNEL = "0x1111111111111111111111111111111111111111";
const ADAPTER = "0x2222222222222222222222222222222222222222";
const UNSTETH_ADAPTER = "0x4444444444444444444444444444444444444444";

test("loopback detection", () => {
  for (const host of ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1", "[::1]", "::ffff:127.0.0.1"]) {
    assert.equal(isLoopbackHost(host), true, host);
  }
  for (const host of ["0.0.0.0", "::", "192.168.1.5", "10.0.0.1", "example.com", "", undefined]) {
    assert.equal(isLoopbackHost(host), false, String(host));
  }
});

test("non-loopback bind is refused with no override", () => {
  assert.deepEqual(assertBindSafe("127.0.0.1"), []);
  assert.throws(() => assertBindSafe("0.0.0.0"), /no configuration override/);
  assert.throws(() => assertBindSafe("192.168.1.5", ""), /loopback/);
  assert.throws(() => assertBindSafe("0.0.0.0", "1"), /no configuration override/);
});

test("the retired kernel is refused unconditionally", () => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: RETIRED_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: "",
  });
  assert.match(refusals.join(" "), /retired/);
  assert.match(refusals.join(" "), /DEPLOYMENT_MANIFEST/);
});

function withManifest(t, manifest) {
  const dir = mkdtempSync(join(tmpdir(), "quote-manifest-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, "manifest.json");
  writeFileSync(path, JSON.stringify(manifest));
  return path;
}

const ACTIVE_MANIFEST = {
  chainId: 1,
  releaseState: "active",
  contracts: {
    kernel: { address: FRESH_KERNEL },
    lidoAdapter: { address: ADAPTER },
    lidoUnstETHExitAdapter: { address: UNSTETH_ADAPTER },
  },
};

test("an active, matching manifest passes", (t) => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: withManifest(t, ACTIVE_MANIFEST),
  });
  assert.deepEqual(refusals, []);
});

test("a retired manifest is refused", (t) => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: withManifest(t, { ...ACTIVE_MANIFEST, releaseState: "retired-paused" }),
  });
  assert.equal(refusals.length, 1);
  assert.match(refusals[0], /retired-paused/);
});

test("a chain-id mismatch is refused", (t) => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: withManifest(t, { ...ACTIVE_MANIFEST, chainId: 11155111 }),
  });
  assert.equal(refusals.length, 1);
  assert.match(refusals[0], /chainId 11155111/);
});

test("an address mismatch is refused", (t) => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: "0x3333333333333333333333333333333333333333",
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: withManifest(t, ACTIVE_MANIFEST),
  });
  assert.equal(refusals.length, 1);
  assert.match(refusals[0], /KERNEL_ADDRESS/);
});

test("an unreadable manifest is refused, not ignored", () => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: "/nonexistent/manifest.json",
  });
  assert.equal(refusals.length, 1);
  assert.match(refusals[0], /unreadable/);
});

test("a missing manifest is refused", () => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: "",
  });
  assert.match(refusals.join(" "), /DEPLOYMENT_MANIFEST/);
});

test("an existing-unstETH adapter mismatch is refused", (t) => {
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: "0x5555555555555555555555555555555555555555",
    manifestPath: withManifest(t, ACTIVE_MANIFEST),
  });
  assert.match(refusals.join(" "), /LIDO_UNSTETH_ADAPTER_ADDRESS/);
});

test("malformed manifest addresses are refused instead of crashing startup", (t) => {
  const malformed = {
    ...ACTIVE_MANIFEST,
    contracts: {
      ...ACTIVE_MANIFEST.contracts,
      lidoUnstETHExitAdapter: { address: "not-an-address" },
    },
  };
  const { refusals } = verifyDeploymentConfig({
    expectedChainId: 1,
    kernel: FRESH_KERNEL,
    lidoAdapter: ADAPTER,
    lidoUnstETHAdapter: UNSTETH_ADAPTER,
    manifestPath: withManifest(t, malformed),
  });
  assert.match(refusals.join(" "), /LIDO_UNSTETH_ADAPTER_ADDRESS/);
});

test("secret material is detected in any obvious encoding", () => {
  const secret = "super-secret-shared-value-0123456789abcdef";
  const key = "0xDEADbeefDEADbeefDEADbeefDEADbeefDEADbeefDEADbeefDEADbeefDEADbeef";

  assert.doesNotThrow(() =>
    assertNoSecretMaterial('{"ok":true,"kernel":"0x1111"}', [secret, key]),
  );
  assert.throws(() => assertNoSecretMaterial(`{"leak":"${secret}"}`, [secret, key]));
  assert.throws(() => assertNoSecretMaterial(`{"leak":"${secret.toUpperCase()}"}`, [secret, key]));
  assert.throws(() => assertNoSecretMaterial(`{"leak":"${key}"}`, [secret, key]));
  // The 0x-stripped hex form of a private key must also be caught.
  assert.throws(() => assertNoSecretMaterial(`{"leak":"${key.slice(2).toLowerCase()}"}`, [secret, key]));
  // The thrown error must not echo the secret.
  try {
    assertNoSecretMaterial(`{"leak":"${secret}"}`, [secret]);
    assert.fail("expected a throw");
  } catch (error) {
    assert.equal(error.message.includes(secret), false);
  }
});
