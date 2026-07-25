// Boot-level behavior of the real server process: bind refusal, /health shape
// with no secret material, and first-class refusal of a retired deployment.
// No chain is required — the RPC endpoint is a dead loopback port and the
// paths exercised here must not depend on it.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SERVER = join(dirname(fileURLToPath(import.meta.url)), "..", "server.mjs");

// Throwaway key material, generated fresh per test run — never a real secret.
function throwawayPrivateKey() {
  const bytes = randomBytes(32);
  bytes[0] &= 0x7f; // stay comfortably below the secp256k1 order
  bytes[31] |= 0x01; // never zero
  return `0x${bytes.toString("hex")}`;
}

const SIGNER_SECRET = `test-secret-${randomBytes(24).toString("hex")}`;
const FAKE_RPC_KEY = `fakerpckey${randomBytes(12).toString("hex")}`;
// Dead port: connections are refused immediately; nothing here may need RPC.
const DEAD_RPC = `http://127.0.0.1:9/${FAKE_RPC_KEY}`;
const KERNEL = "0x1111111111111111111111111111111111111111";
const ADAPTER = "0x2222222222222222222222222222222222222222";
const UNSTETH_ADAPTER = "0x4444444444444444444444444444444444444444";

function baseEnv(tempDir, privateKey) {
  const manifestPath = join(tempDir, "active-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({
      chainId: 1,
      releaseState: "active",
      contracts: {
        kernel: { address: KERNEL },
        lidoAdapter: { address: ADAPTER },
        lidoUnstETHExitAdapter: { address: UNSTETH_ADAPTER },
      },
    }),
  );
  return {
    ...process.env,
    HOST: "127.0.0.1",
    PORT: "0",
    ETH_RPC_URL: DEAD_RPC,
    FACTOR_PRIVATE_KEY: privateKey,
    KERNEL_ADDRESS: KERNEL,
    LIDO_ADAPTER_ADDRESS: ADAPTER,
    LIDO_UNSTETH_ADAPTER_ADDRESS: UNSTETH_ADAPTER,
    SIGNER_SECRET,
    MAX_QUOTE_WEI: "6000000000000000",
    AUDIT_LOG: join(tempDir, "quote-audit.jsonl"),
    RESERVATIONS_DB: join(tempDir, "quote-reservations.sqlite"),
    DEPLOYMENT_MANIFEST: manifestPath,
  };
}

function startServer(env) {
  const child = spawn(process.execPath, [SERVER], { env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => (stdout += chunk));
  child.stderr.on("data", (chunk) => (stderr += chunk));
  return {
    child,
    get stdout() {
      return stdout;
    },
    get stderr() {
      return stderr;
    },
    exited: new Promise((resolvePromise) => child.on("exit", (code) => resolvePromise(code))),
    async waitForListening(timeoutMs = 8000) {
      const startedAt = Date.now();
      for (;;) {
        for (const line of stdout.split("\n")) {
          if (!line.trim()) continue;
          try {
            const parsed = JSON.parse(line);
            if (parsed.event === "listening") return parsed;
          } catch {
            // non-JSON log line
          }
        }
        if (child.exitCode !== null) {
          throw new Error(`server exited early (code ${child.exitCode}): ${stderr}`);
        }
        if (Date.now() - startedAt > timeoutMs) {
          throw new Error(`server did not report listening in time: ${stdout} ${stderr}`);
        }
        await new Promise((r) => setTimeout(r, 50));
      }
    },
    stop() {
      if (child.exitCode === null) child.kill("SIGTERM");
    },
  };
}

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), "quote-signer-boot-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("a non-loopback HOST refuses to start", async (t) => {
  const dir = tempDir(t);
  const env = { ...baseEnv(dir, throwawayPrivateKey()), HOST: "0.0.0.0" };
  const server = startServer(env);
  t.after(() => server.stop());

  const code = await server.exited;
  assert.notEqual(code, 0, "process must exit non-zero");
  assert.match(server.stderr, /no configuration override/);
  assert.doesNotMatch(server.stdout, /"event":"listening"/);
});

test("ALLOW_NONLOCAL_BIND cannot override the loopback-only posture", async (t) => {
  const dir = tempDir(t);
  const env = { ...baseEnv(dir, throwawayPrivateKey()), HOST: "0.0.0.0", ALLOW_NONLOCAL_BIND: "1" };
  const server = startServer(env);
  t.after(() => server.stop());

  const code = await server.exited;
  assert.notEqual(code, 0);
  assert.match(server.stderr, /no configuration override/);
});

test("/health exposes readiness, chain id, and addresses — and no secret material", async (t) => {
  const dir = tempDir(t);
  const privateKey = throwawayPrivateKey();
  const server = startServer(baseEnv(dir, privateKey));
  t.after(() => server.stop());

  const { port } = await server.waitForListening();
  const response = await fetch(`http://127.0.0.1:${port}/health`);
  assert.equal(response.status, 200);
  const body = await response.text();
  const payload = JSON.parse(body);

  // Shape: everything the operator needs to see.
  assert.equal(payload.service, "reservoir-quote-signer");
  assert.ok(["pending", "error"].includes(payload.readiness.state), payload.readiness.state);
  assert.equal(payload.ok, false, "not ready without a chain");
  assert.equal(payload.chain.expectedChainId, 1);
  assert.equal(payload.contracts.kernel, KERNEL);
  assert.equal(payload.contracts.lidoAdapter, ADAPTER);
  assert.equal(payload.contracts.lidoUnstETHAdapter, UNSTETH_ADAPTER);
  assert.ok("kernelPaused" in payload.settlement);
  assert.ok("availableWei" in payload.capacity);
  assert.equal(payload.reservations.backend, "sqlite");
  assert.match(payload.pricing.basis, /not a market/);

  // No secret material, in any encoding.
  const haystack = body.toLowerCase();
  assert.equal(haystack.includes(SIGNER_SECRET.toLowerCase()), false, "signer secret leaked");
  assert.equal(haystack.includes(privateKey.toLowerCase()), false, "private key leaked");
  assert.equal(haystack.includes(privateKey.slice(2).toLowerCase()), false, "raw key hex leaked");
  assert.equal(haystack.includes(FAKE_RPC_KEY.toLowerCase()), false, "rpc url leaked");
});

test("a retired manifest is a first-class refusal: /health says so and /quote is 503", async (t) => {
  const dir = tempDir(t);
  const manifestPath = join(dir, "manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({
      chainId: 1,
      releaseState: "retired-paused",
      contracts: {
        kernel: { address: KERNEL },
        lidoAdapter: { address: ADAPTER },
        lidoUnstETHExitAdapter: { address: UNSTETH_ADAPTER },
      },
    }),
  );
  const env = { ...baseEnv(dir, throwawayPrivateKey()), DEPLOYMENT_MANIFEST: manifestPath };
  const server = startServer(env);
  t.after(() => server.stop());

  const { port } = await server.waitForListening();

  const health = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
  assert.equal(health.ok, false);
  assert.equal(health.readiness.state, "refused");
  assert.match(health.readiness.reasons.join(" "), /retired-paused/);

  // Per-request enforcement: an authorized quote request is refused with 503
  // before any pricing or signing happens — and without needing the RPC.
  const quote = await fetch(`http://127.0.0.1:${port}/quote`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-signer-secret": SIGNER_SECRET },
    body: JSON.stringify({
      seller: "0x528C4E1d59fD4b187461BE9c61C668928C3cf9c3",
      mode: "originate",
      requestedStEth: "5000000000000000",
    }),
  });
  assert.equal(quote.status, 503);
  const quoteBody = await quote.json();
  assert.equal(quoteBody.code, "REFUSED_DEPLOYMENT");
});
