/**
 * CoreCredit — iPad App Store marketing template generator.
 *
 * Renders six 2752 x 2064 templates that share one design system: identical
 * background, identical device placement, identical type scale. Only the
 * headline and the supporting line change between images.
 *
 * The iPad screen is left as a flat neutral aperture at exactly 4:3, so a real
 * 2752 x 2064 capture drops straight in with no scaling and no distortion.
 */

import { chromium } from 'playwright';
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(process.argv[2] || join(HERE, 'out')); // absolute: file:// URLs below
mkdirSync(OUT, { recursive: true });

/* ---------------------------------------------------------------- canvas -- */

const CANVAS_W = 2752;
const CANVAS_H = 2064;

/* ---------------------------------------------------------------- device -- */
/* The screen is 1475 x 1025 — exactly 59:41, the aspect of the 2360 x 1640
   captures this app produces. A capture therefore scales in at exactly 0.625
   with no crop and no stretch. A 4:3 aperture would have forced a centre crop
   that ate 67 columns of the sidebar and up to 87 of the right-hand chevrons. */

const SHOT_W = 2360;
const SHOT_H = 1640;
const SCREEN_W = 1475;                       // SHOT_W * 0.625
const SCREEN_H = 1025;                       // SHOT_H * 0.625
const BEZEL = 30;
const BODY_W = SCREEN_W + BEZEL * 2;         // 1535
const BODY_H = SCREEN_H + BEZEL * 2;         // 1085
const BODY_X = 1086;                         // right of centre; copy sits left
const BODY_Y = 479;                          // same optical centre as before
const SCREEN_RADIUS = 35;
const BODY_RADIUS = SCREEN_RADIUS + BEZEL;

/* ------------------------------------------------------------------ type -- */

const TEXT_X = 172;
const TEXT_W = 830;
const HEADLINE_SIZE = 114;
const SUB_SIZE = 48;

/* ------------------------------------------------------------------ copy -- */
/* Line breaks are authored, not left to the wrap engine: a marketing headline
   should break on sense, and the break has to be identical every rebuild. */

const IMAGES = [
  {
    slug: 'full-picture',
    headline: ['See your full', 'core-credit', 'picture.'],
    sub: 'Track money at risk, overdue returns, and priorities in one place.',
  },
  {
    slug: 'capture',
    headline: ['Capture a core', 'in seconds.'],
    sub: 'Scan it. Review the details. Save.',
  },
  {
    slug: 'workspace',
    headline: ['Every core.', 'One organized', 'workspace.'],
    sub: 'Search, filter, and review every return without losing context.',
  },
  {
    slug: 'returns-moving',
    headline: ['Keep returns', 'moving.'],
    sub: 'Group cores by vendor and stay on top of what’s ready to go back.',
  },
  {
    slug: 'still-owed',
    headline: ['Know exactly', 'what you’re', 'still owed.'],
    sub: 'Compare expected credits with what vendors actually paid.',
  },
  {
    slug: 'every-step',
    headline: ['Follow every', 'step to credit.'],
    sub: 'From received core to confirmed credit, every event stays visible.',
  },
];

/* The four screens that get a real capture. Three carry copy of their own
   rather than reusing a blank template's supporting line. */

const FINALS = [
  {
    slug: 'dashboard',
    shot: 'dashboard',
    headline: ['See your full', 'core-credit', 'picture.'],
    sub: 'Track money at risk, overdue returns, and priorities in one place.',
  },
  {
    slug: 'cores',
    shot: 'cores',
    headline: ['Every core.', 'One reconciled', 'workspace.'],
    sub: 'Search, sort, and review every core in one organized view.',
  },
  {
    slug: 'returns',
    shot: 'returns',
    headline: ['Keep returns', 'moving.'],
    sub: 'See open returns, returned cores, and credits still pending.',
  },
  {
    slug: 'timeline',
    shot: 'alternator',
    headline: ['Follow every', 'step to credit.'],
    sub: 'See the full timeline from logged core to recorded vendor credit.',
  },
];

/* ----------------------------------------------------------------- fonts -- */

const weights = [500, 600, 800]; // subtitle + placeholder label, label caps, headline
const faces = weights
  .map((w) => {
    const b64 = readFileSync(join(HERE, 'fonts', `Inter-${w}.ttf`)).toString('base64');
    return `@font-face{font-family:Inter;font-style:normal;font-weight:${w};` +
      `src:url(data:font/ttf;base64,${b64}) format('truetype');}`;
  })
  .join('\n');

/* ------------------------------------------------------------------ page -- */

const esc = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function page({ headline, sub }, placeholder = true) {
  const lines = headline.map((l) => `<span class="ln">${esc(l)}</span>`).join('');
  return `<!doctype html>
<html><head><meta charset="utf-8"><style>
${faces}

*{margin:0;padding:0;box-sizing:border-box;}
html,body{width:${CANVAS_W}px;height:${CANVAS_H}px;overflow:hidden;background:#143D84;}

.canvas{
  position:relative;width:${CANVAS_W}px;height:${CANVAS_H}px;overflow:hidden;
  font-family:Inter,sans-serif;
  -webkit-font-smoothing:antialiased;
  text-rendering:geometricPrecision;
}

/* -- background ------------------------------------------------------- */
/* Deep navy field lifted by one broad blue glow behind and below the device,
   the same luminance shape the iPhone set uses. Corners stay deep so both the
   device edge and the white type keep their contrast. */
.bg{
  position:absolute;inset:0;
  background:
    radial-gradient(72% 88% at 62% 48%, #4E9BF6 0%, rgba(66,145,238,0.66) 26%,
                    rgba(40,104,200,0.36) 50%, rgba(24,70,148,0.11) 74%,
                    rgba(20,61,132,0) 90%),
    radial-gradient(64% 70% at 16% 60%, rgba(58,131,226,0.30) 0%,
                    rgba(48,116,208,0.14) 44%, rgba(20,61,132,0) 78%),
    linear-gradient(176deg, #11356F 0%, #143D84 32%, #17468F 60%, #123670 100%);
}
/* Corner falloff — frames the composition and keeps the glow from reading flat. */
.vignette{
  position:absolute;inset:0;
  background:radial-gradient(118% 110% at 52% 50%, rgba(8,26,62,0) 48%,
             rgba(8,26,62,0.22) 80%, rgba(7,22,56,0.42) 100%);
}
/* -- copy ------------------------------------------------------------- */
.copy{
  position:absolute;left:${TEXT_X}px;width:${TEXT_W}px;
  top:${BODY_Y + BODY_H / 2}px;transform:translateY(-50%);
}
h1{
  font-size:${HEADLINE_SIZE}px;
  font-weight:800;
  line-height:1.045;
  letter-spacing:-0.030em;
  color:#FFFFFF;
}
h1 .ln{display:block;width:fit-content;white-space:nowrap;}
p{
  margin-top:48px;
  font-size:${SUB_SIZE}px;
  font-weight:500;
  line-height:1.38;
  letter-spacing:-0.006em;
  color:rgba(255,255,255,0.90);
}

/* -- device ----------------------------------------------------------- */
/* Shadow lives on its own layers so the body keeps a crisp edge: one broad
   ambient pool, one tighter contact shadow just under the device. */
.shadow-ambient{
  position:absolute;
  left:${BODY_X + 30}px;
  top:${BODY_Y + 120}px;
  width:${BODY_W - 60}px;
  height:${BODY_H - 40}px;
  border-radius:${BODY_RADIUS}px;
  background:rgba(5,18,48,0.62);
  filter:blur(96px);
}
.shadow-contact{
  position:absolute;
  left:${BODY_X + 14}px;
  top:${BODY_Y + 34}px;
  width:${BODY_W - 28}px;
  height:${BODY_H - 4}px;
  border-radius:${BODY_RADIUS}px;
  background:rgba(6,20,52,0.50);
  filter:blur(30px);
}

/* Outer aluminium rim, lit from the upper left. */
.device{
  position:absolute;
  left:${BODY_X}px;top:${BODY_Y}px;
  width:${BODY_W}px;height:${BODY_H}px;
  border-radius:${BODY_RADIUS}px;
  background:linear-gradient(148deg,
    #AEB8C5 0%, #7C8794 5%, #434C57 12%,
    #2A3038 34%, #22272E 64%,
    #2C323A 88%, #59626E 97%, #7E8895 100%);
}
/* Dark bezel band inside the rim. */
.device-body{
  position:absolute;inset:4px;
  border-radius:${BODY_RADIUS - 4}px;
  background:linear-gradient(156deg, #23272E 0%, #15181D 24%, #0E1115 54%, #171A1F 80%, #262B33 100%);
}
/* Specular catch along the top-left edge of the bezel. Painted before the
   screen so the aperture itself stays exactly one flat colour. */
.device-gloss{
  position:absolute;inset:4px;
  border-radius:${BODY_RADIUS - 4}px;
  background:linear-gradient(151deg, rgba(255,255,255,0.16) 0%,
             rgba(255,255,255,0.05) 8%, rgba(255,255,255,0) 26%,
             rgba(255,255,255,0) 76%, rgba(255,255,255,0.032) 96%,
             rgba(255,255,255,0.06) 100%);
  pointer-events:none;
}
/* Hairline where the bezel meets the glass. */
.screen-well{
  position:absolute;
  left:${BEZEL - 4}px;top:${BEZEL - 4}px;
  width:${SCREEN_W + 8}px;height:${SCREEN_H + 8}px;
  border-radius:${SCREEN_RADIUS + 4}px;
  background:#04060A;
}

/* -- the aperture: flat, neutral, ready for a real capture ------------- */
.screen{
  position:absolute;
  left:${BEZEL}px;top:${BEZEL}px;
  width:${SCREEN_W}px;height:${SCREEN_H}px;
  border-radius:${SCREEN_RADIUS}px;
  background:#F1F5FA;
  display:flex;flex-direction:column;
  align-items:center;justify-content:center;
  gap:20px;
}
.ph-1{
  font-size:29px;font-weight:600;letter-spacing:0.30em;
  color:#9CA7B6;text-indent:0.30em;
}
.ph-2{
  font-size:25px;font-weight:500;letter-spacing:0.16em;
  color:#BAC3CF;text-indent:0.16em;
}
/* Front camera, centred on the landscape top edge. Hardware, not app UI. */
.camera{
  position:absolute;
  top:${Math.round(BEZEL / 2) - 5}px;
  left:${Math.round(BODY_W / 2) - 5}px;
  width:10px;height:10px;border-radius:50%;
  background:radial-gradient(circle at 36% 32%, #39414C 0%, #161A20 60%, #0A0D11 100%);
}
</style></head>
<body>
  <div class="canvas">
    <div class="bg"></div>
    <div class="vignette"></div>

    <div class="copy">
      <h1>${lines}</h1>
      <p>${esc(sub)}</p>
    </div>

    <div class="shadow-ambient"></div>
    <div class="shadow-contact"></div>
    <div class="device">
      <div class="device-body">
        <div class="device-gloss"></div>
        <div class="screen-well"></div>
        <div class="screen">${placeholder ? `
          <div class="ph-1">REPLACE WITH REAL IPAD SCREENSHOT</div>
          <div class="ph-2">${SHOT_W} &times; ${SHOT_H}</div>` : ''}
        </div>
        <div class="camera"></div>
      </div>
    </div>
  </div>
</body></html>`;
}

/* ---------------------------------------------------------------- render -- */

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: CANVAS_W, height: CANVAS_H },
  deviceScaleFactor: 1,
});
const p = await ctx.newPage();

let worstHead = 0;
let overflow = false;

/** Render one page and report how the authored copy fits its column. */
async function render(img, file, placeholder) {
  const tmp = join(OUT, `.${img.slug}.html`);
  writeFileSync(tmp, page(img, placeholder));
  await p.goto('file://' + tmp);
  await p.evaluate(() => document.fonts.ready);

  const m = await p.evaluate((SUB_SIZE) => {
    const lines = [...document.querySelectorAll('h1 .ln')]
      .map((el) => Math.round(el.getBoundingClientRect().width));
    const sub = document.querySelector('p').getBoundingClientRect();
    const copy = document.querySelector('.copy').getBoundingClientRect();
    return {
      lines,
      subLines: Math.round(sub.height / (SUB_SIZE * 1.38)),
      copyRight: Math.round(copy.left + Math.max(...lines, sub.width)),
    };
  }, SUB_SIZE);

  const longest = Math.max(...m.lines);
  worstHead = Math.max(worstHead, longest);
  const fits = longest <= TEXT_W && m.copyRight < BODY_X - 40;
  if (!fits) overflow = true;

  await p.screenshot({ path: file, type: 'png' });
  rmSync(tmp);                       // the page is a build artefact, not output
  console.log(`  ${img.slug.padEnd(15)} head[${m.lines.join(',')}] ` +
    `max=${longest}/${TEXT_W} sub=${m.subLines}ln ${fits ? 'ok' : 'OVERFLOW'}`);
}

console.log('blank templates:');
let n = 1;
for (const img of IMAGES) {
  await render(img, join(OUT, `CoreCredit_iPad_${String(n).padStart(2, '0')}_${img.slug}.png`), true);
  n++;
}

/* Plates carry no placeholder label: a capture covers the aperture entirely. */
const PLATES = join(OUT, '_plates');
mkdirSync(PLATES, { recursive: true });
console.log('\nplates for the finished images:');
for (const img of FINALS) await render(img, join(PLATES, `${img.slug}.png`), false);

const spec = {
  canvas: { width: CANVAS_W, height: CANVAS_H },
  screenAperture: {
    x: BODY_X + BEZEL,
    y: BODY_Y + BEZEL,
    width: SCREEN_W,
    height: SCREEN_H,
    cornerRadius: SCREEN_RADIUS,
    aspect: `${SCREEN_W}:${SCREEN_H} — exactly ${SHOT_W}:${SHOT_H}, the capture aspect`,
  },
  deviceBody: { x: BODY_X, y: BODY_Y, width: BODY_W, height: BODY_H },
  captureSize: { width: SHOT_W, height: SHOT_H },
  scaleFromCapture: +(SCREEN_W / SHOT_W).toFixed(6),
};
writeFileSync(join(OUT, 'template-spec.json'), JSON.stringify(spec, null, 2) + '\n');
console.log('\naperture', JSON.stringify(spec.screenAperture));
console.log(`widest headline line: ${worstHead}px of ${TEXT_W}px column`);
console.log(overflow ? 'FAIL: a line overflows' : 'all lines fit');
await browser.close();
