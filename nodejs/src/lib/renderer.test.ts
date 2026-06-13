import { test, describe } from 'node:test';
import assert from 'node:assert';
import { Renderer, RenderOptions } from './renderer.js';

function makeRenderer(options: Partial<RenderOptions> = {}): Renderer {
  return new Renderer('test.txt', {
    speed: 0.5,
    isSlideshow: false,
    useInverted: false,
    eccLevel: 'L',
    ...options,
  });
}

/** Temporarily overrides process.stdout.columns/rows for the duration of `fn`. */
function withTerminalSize<T>(cols: number, rows: number, fn: () => T): T {
  const originalCols = Object.getOwnPropertyDescriptor(process.stdout, 'columns');
  const originalRows = Object.getOwnPropertyDescriptor(process.stdout, 'rows');
  Object.defineProperty(process.stdout, 'columns', { value: cols, configurable: true });
  Object.defineProperty(process.stdout, 'rows', { value: rows, configurable: true });
  try {
    return fn();
  } finally {
    if (originalCols) Object.defineProperty(process.stdout, 'columns', originalCols);
    if (originalRows) Object.defineProperty(process.stdout, 'rows', originalRows);
  }
}

describe('Renderer QR sizing', () => {
  test('qrColumnWidth and qrRowHeight follow the version formula', () => {
    const r = makeRenderer();
    r.version = 2;
    // moduleCount = version * 4 + 17; columnWidth = moduleCount + 3
    assert.strictEqual((r as any).qrColumnWidth(), 2 * 4 + 17 + 3);
    // rowHeight = version * 2 + 10
    assert.strictEqual((r as any).qrRowHeight(), 2 * 2 + 10);

    r.version = 5;
    assert.strictEqual((r as any).qrColumnWidth(), 5 * 4 + 17 + 3);
    assert.strictEqual((r as any).qrRowHeight(), 5 * 2 + 10);
  });
});

describe('Renderer.gridDimensions', () => {
  test('lays out 1-4 codes into the expected columns/rows', () => {
    const r = makeRenderer();
    r.version = 2;
    const colWidth = (r as any).qrColumnWidth();
    const rowHeight = (r as any).qrRowHeight();

    const one = (r as any).gridDimensions(1);
    assert.deepStrictEqual(one, { cols: 1, rows: 1, width: colWidth, height: rowHeight });

    const two = (r as any).gridDimensions(2);
    assert.strictEqual(two.cols, 2);
    assert.strictEqual(two.rows, 1);
    assert.strictEqual(two.width, 2 * colWidth + 2); // GRID_GAP_X = 2

    const three = (r as any).gridDimensions(3);
    assert.strictEqual(three.cols, 2);
    assert.strictEqual(three.rows, 2);

    const four = (r as any).gridDimensions(4);
    assert.strictEqual(four.cols, 2);
    assert.strictEqual(four.rows, 2);
    assert.strictEqual(four.width, 2 * colWidth + 2);
    assert.strictEqual(four.height, 2 * rowHeight + 1); // GRID_GAP_Y = 1
  });
});

describe('Renderer.effectiveMultiQr', () => {
  test('returns the configured value when the grid fits the terminal', () => {
    const r = makeRenderer({ multiQr: 4 });
    r.version = 2;
    withTerminalSize(120, 30, () => {
      assert.strictEqual((r as any).effectiveMultiQr(), 4);
    });
  });

  test('falls back to a smaller grid when the terminal is too small', () => {
    const r = makeRenderer({ multiQr: 4 });
    r.version = 2;
    withTerminalSize(80, 24, () => {
      assert.strictEqual((r as any).effectiveMultiQr(), 2);
    });
  });

  test('falls back to 1 when nothing larger fits', () => {
    const r = makeRenderer({ multiQr: 4 });
    r.version = 2;
    withTerminalSize(40, 24, () => {
      assert.strictEqual((r as any).effectiveMultiQr(), 1);
    });
  });

  test('defaults to 1 when multiQr is not configured', () => {
    const r = makeRenderer();
    r.version = 2;
    withTerminalSize(200, 60, () => {
      assert.strictEqual((r as any).effectiveMultiQr(), 1);
    });
  });
});

describe('Renderer navigation', () => {
  test('moveNext/movePrev step by effectiveMultiQr and clamp at the bounds', () => {
    const r = makeRenderer({ multiQr: 2 });
    r.version = 2;
    r.setChunks(['a', 'b', 'c', 'd', 'e'], 2);

    withTerminalSize(120, 30, () => {
      assert.strictEqual((r as any).effectiveMultiQr(), 2);

      assert.strictEqual(r.index, 0);
      r.moveNext();
      assert.strictEqual(r.index, 2);
      r.moveNext();
      assert.strictEqual(r.index, 4); // clamped to chunks.length - 1
      r.moveNext();
      assert.strictEqual(r.index, 4); // stays clamped

      r.movePrev();
      assert.strictEqual(r.index, 2);
      r.movePrev();
      assert.strictEqual(r.index, 0);
      r.movePrev();
      assert.strictEqual(r.index, 0); // clamped to 0
    });
  });

  test('setChunks resets index to 0 if it is now out of bounds', () => {
    const r = makeRenderer();
    r.setChunks(['a', 'b', 'c'], 2);
    r.index = 2;
    r.setChunks(['x'], 2);
    assert.strictEqual(r.index, 0);
  });

  test('setChunks keeps a still-valid index', () => {
    const r = makeRenderer();
    r.setChunks(['a', 'b', 'c'], 2);
    r.index = 1;
    r.setChunks(['x', 'y'], 2);
    assert.strictEqual(r.index, 1);
  });
});
