import test from "node:test";
import assert from "node:assert/strict";

import { SerialExecutor } from "../serial-executor.mjs";

function deferred() {
  let resolve;
  const promise = new Promise((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

test("concurrent quote critical sections never overlap", async () => {
  const executor = new SerialExecutor();
  const firstMayFinish = deferred();
  const events = [];

  const first = executor.run(async () => {
    events.push("first:start");
    await firstMayFinish.promise;
    events.push("first:end");
    return "first";
  });
  const second = executor.run(async () => {
    events.push("second:start");
    events.push("second:end");
    return "second";
  });

  await Promise.resolve();
  assert.deepEqual(events, ["first:start"]);

  firstMayFinish.resolve();
  assert.deepEqual(await Promise.all([first, second]), ["first", "second"]);
  assert.deepEqual(events, [
    "first:start",
    "first:end",
    "second:start",
    "second:end",
  ]);
});

test("a failed quote releases the next request", async () => {
  const executor = new SerialExecutor();
  const expected = new Error("quote refused");

  const first = executor.run(async () => {
    throw expected;
  });
  const second = executor.run(async () => "next quote ran");

  await assert.rejects(first, expected);
  assert.equal(await second, "next quote ran");
});
