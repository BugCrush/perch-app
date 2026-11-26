// What walker.mjs needs from the packages, computed once: the bird (from the logo) and the
// letters of Manrope for its labels, as path data.
import { fonts, birdPaths, birdClip, round0 } from './lib.mjs';

/// The wing in logo units (the app's `_wing` in mosaic.dart) and the shoulder it turns about.
const wing = [
  [232, 548], [250, 500], [320, 425], [395, 352], [468, 300], [540, 266], [612, 258], [652, 276],
  [660, 318], [648, 356], [612, 404], [566, 448], [500, 490], [420, 522], [330, 548], [270, 560],
];

export function walkerData() {
  const bird = birdPaths({ tolerance: 2 });
  const font = fonts.sansBold;
  const glyphs = {};
  for (let c = 32; c < 127; c++) {
    const ch = String.fromCharCode(c);
    const g = font.charToGlyph(ch);
    glyphs[ch] = { a: g.advanceWidth, d: round0(g.getPath(0, 0, font.unitsPerEm).toPathData(0)) };
  }
  for (const ch of ['·', '–']) {
    const g = font.charToGlyph(ch);
    glyphs[ch] = { a: g.advanceWidth, d: round0(g.getPath(0, 0, font.unitsPerEm).toPathData(0)) };
  }
  return {
    bird: {
      orange: bird.orange,
      cream: bird.cream,
      clip: birdClip,
      wing,
      shoulder: [612, 300],
      feet: [560, 621],
      height: 600,
    },
    font: { upm: font.unitsPerEm, glyphs },
  };
}
