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
  assert.match(stylesheet, /right: -120px/);
  assert.match(stylesheet, /bottom: -150px/);
  assert.match(stylesheet, /repeating-radial-gradient/);
  assert.match(stylesheet, /radial-gradient/);
  assert.match(stylesheet, /pointer-events: none/);
  assert.match(stylesheet, /mask-image/);
});
