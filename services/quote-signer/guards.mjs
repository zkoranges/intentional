// Startup and per-request guards for the quote signer:
//   - bind safety: the desk's posture is loopback-only behind a tunnel; a
//     non-loopback HOST is refused at startup unless explicitly overridden;
//   - deployment refusal: retired / mismatched deployments are refused as a
//     first-class readiness state, not discovered as a late runtime error;
//   - secret hygiene: outbound health payloads are asserted free of secret
//     material before they leave the process.

import { readFileSync } from "node:fs";
import { getAddress } from "viem";

// Deployments that must never be quoted against outside a local fork
// rehearsal. The v2 kernel is retired: its factor key was exposed and the
// deployment is paused for good. Checksummed for exact comparison.
export const RETIRED_KERNELS = new Set([
  getAddress("0x50b619295e00990feB28E79fA939B5f42aF6AF53"), // Reservoir v2 — retired-paused, key exposed
]);

export function isLoopbackHost(host) {
  if (typeof host !== "string" || host.length === 0) return false;
  const bare = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (bare === "localhost" || bare === "::1" || bare === "0:0:0:0:0:0:0:1") return true;
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(bare)) return true;
  if (bare.startsWith("::ffff:127.")) return true;
  return false;
}

export function isLoopbackUrl(url) {
  try {
    return isLoopbackHost(new URL(url).hostname);
  } catch {
    return false;
  }
}

/**
 * The desk binds loopback only; public exposure is a tunnel in front of it.
 * A stray HOST=0.0.0.0 silently violates that posture, so it is a startup
 * refusal unless the operator sets ALLOW_NONLOCAL_BIND=1 knowingly.
 * Returns a list of warnings to log; throws on refusal.
 */
export function assertBindSafe(host, allowNonlocalBind) {
  if (isLoopbackHost(host)) return [];
  if (allowNonlocalBind === "1") {
    return [
      `WARNING: binding non-loopback host ${host} because ALLOW_NONLOCAL_BIND=1 — ` +
        "the reviewed posture is 127.0.0.1 behind a named tunnel; anyone who can " +
        "reach this socket only needs the shared secret to request signed quotes",
    ];
  }
  throw new Error(
    `refusing to bind non-loopback host ${host}: the quote desk's posture is ` +
      "loopback-only behind a tunnel. Set ALLOW_NONLOCAL_BIND=1 only if you " +
      "understand the exposure and have compensating network controls.",
  );
}

/**
 * Config-level deployment verification, computed once at startup (the inputs
 * are process configuration, so the result cannot change until restart) and
 * enforced on every request. Returns { refusals, manifest }; a non-empty
 * refusal list is the "refused" readiness state.
 */
export function verifyDeploymentConfig({
  expectedChainId,
  kernel,
  lidoAdapter,
  rpcUrl,
  manifestPath,
}) {
  const refusals = [];
  let manifest = null;

  if (RETIRED_KERNELS.has(getAddress(kernel)) && !isLoopbackUrl(rpcUrl)) {
    refusals.push(
      `kernel ${kernel} is a retired deployment; it may only be targeted by a ` +
        "local fork rehearsal (loopback RPC), never over a live RPC endpoint",
    );
  }

  if (manifestPath) {
    try {
      manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    } catch (error) {
      refusals.push(`deployment manifest ${manifestPath} is unreadable: ${error.message}`);
      return { refusals, manifest: null };
    }

    if (manifest.releaseState !== "active") {
      refusals.push(
        `deployment manifest releaseState is "${manifest.releaseState}" — ` +
          'only an "active" deployment may be quoted against',
      );
    }
    if (Number(manifest.chainId) !== Number(expectedChainId)) {
      refusals.push(
        `deployment manifest chainId ${manifest.chainId} does not match the ` +
          `configured chain id ${expectedChainId}`,
      );
    }
    const manifestKernel = manifest.contracts?.kernel?.address;
    if (!manifestKernel || getAddress(manifestKernel) !== getAddress(kernel)) {
      refusals.push(
        `configured KERNEL_ADDRESS ${kernel} does not match the manifest kernel ` +
          `${manifestKernel ?? "<missing>"}`,
      );
    }
    const manifestAdapter = manifest.contracts?.lidoAdapter?.address;
    if (!manifestAdapter || getAddress(manifestAdapter) !== getAddress(lidoAdapter)) {
      refusals.push(
        `configured LIDO_ADAPTER_ADDRESS ${lidoAdapter} does not match the ` +
          `manifest lidoAdapter ${manifestAdapter ?? "<missing>"}`,
      );
    }
  }

  return { refusals, manifest };
}

/**
 * Assert that an outbound payload carries none of the given secret values in
 * any obvious encoding (verbatim, lowercased, or hex without its 0x prefix).
 * Throws a generic error — the message never includes the secret itself.
 */
export function assertNoSecretMaterial(payload, secrets) {
  const haystackLower = payload.toLowerCase();
  for (const secret of secrets) {
    if (typeof secret !== "string" || secret.length < 8) continue;
    const variants = new Set([secret.toLowerCase()]);
    if (secret.toLowerCase().startsWith("0x") && secret.length > 10) {
      variants.add(secret.slice(2).toLowerCase());
    }
    for (const variant of variants) {
      if (haystackLower.includes(variant)) {
        throw new Error("outbound payload contains secret material; refusing to send it");
      }
    }
  }
}
