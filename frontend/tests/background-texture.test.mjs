import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the app includes a restrained gavel line-art backdrop", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const stylesheet = await readFile(
    new URL("app/globals.css", projectRoot),
    "utf8",
  );

  assert.match(page, /className="gavelBackdrop"/);
  assert.match(stylesheet, /\.gavelBackdrop \{/);
  assert.match(stylesheet, /position: absolute/);
  assert.match(stylesheet, /top: 72px/);
  assert.match(stylesheet, /right: 0/);
  assert.match(stylesheet, /opacity: 0.2/);
  assert.match(stylesheet, /display: none/);
  assert.match(stylesheet, /gavel-impact-line\.png/);
  assert.match(stylesheet, /pointer-events: none/);
  assert.match(stylesheet, /overflow-x: hidden/);

  const texture = await readFile(
    new URL("public/textures/gavel-impact-line.png", projectRoot),
  );
  assert.ok(texture.byteLength > 10_000);
});
