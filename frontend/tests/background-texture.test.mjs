import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the app includes a non-interactive lower-right fintech texture", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const stylesheet = await readFile(
    new URL("app/globals.css", projectRoot),
    "utf8",
  );

  assert.match(page, /className="fintechTexture" aria-hidden="true"/);
  assert.match(stylesheet, /\.fintechTexture \{/);
  assert.match(stylesheet, /position: fixed/);
  assert.match(stylesheet, /right: -68px/);
  assert.match(stylesheet, /bottom: -34px/);
  assert.match(stylesheet, /impatience-flow\.svg/);
  assert.match(stylesheet, /pointer-events: none/);
  assert.doesNotMatch(stylesheet, /repeating-radial-gradient/);

  const texture = await readFile(
    new URL("public/textures/impatience-flow.svg", projectRoot),
    "utf8",
  );
  assert.match(texture, /id="fastLane"/);
  assert.match(texture, /id="ledger"/);
  assert.match(texture, /#A78BFA/);
});
