import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the app includes subtle mirrored time-compression textures", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const stylesheet = await readFile(
    new URL("app/globals.css", projectRoot),
    "utf8",
  );

  assert.match(page, /fintechTexture fintechTextureLeft/);
  assert.match(page, /fintechTexture fintechTextureRight/);
  assert.match(stylesheet, /\.fintechTexture \{/);
  assert.match(stylesheet, /position: absolute/);
  assert.match(stylesheet, /top: 96px/);
  assert.match(stylesheet, /left: -112px/);
  assert.match(stylesheet, /right: -112px/);
  assert.match(stylesheet, /transform: scaleX\(-1\)/);
  assert.match(stylesheet, /opacity: 0.25/);
  assert.match(stylesheet, /display: none/);
  assert.match(stylesheet, /impatience-flow\.svg/);
  assert.match(stylesheet, /pointer-events: none/);
  assert.doesNotMatch(stylesheet, /repeating-radial-gradient/);

  const texture = await readFile(
    new URL("public/textures/impatience-flow.svg", projectRoot),
    "utf8",
  );
  assert.match(texture, /id="timeline"/);
  assert.match(texture, /id="ticks"/);
  assert.doesNotMatch(texture, /#A78BFA|#8B5CF6/i);
});
