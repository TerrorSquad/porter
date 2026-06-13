import { test, describe } from 'node:test';
import assert from 'node:assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { StateManager } from './state.js';

/** Runs `fn` inside a fresh temp directory used as cwd, restoring cwd afterwards. */
function inTmpCwd<T>(fn: (dir: string) => T): T {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'porter-state-'));
  const origCwd = process.cwd();
  process.chdir(dir);
  try {
    return fn(dir);
  } finally {
    process.chdir(origCwd);
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

describe('StateManager', () => {
  test('loadProgress returns 0 when no history file exists', () => {
    inTmpCwd(() => {
      assert.strictEqual(StateManager.loadProgress('myfile.txt'), 0);
    });
  });

  test('saveProgress and loadProgress round-trip', () => {
    inTmpCwd(() => {
      StateManager.saveProgress('myfile.txt', 5);
      assert.strictEqual(StateManager.loadProgress('myfile.txt'), 5);

      StateManager.saveProgress('myfile.txt', 12);
      assert.strictEqual(StateManager.loadProgress('myfile.txt'), 12);
    });
  });

  test('loadProgress returns 0 when the history file is corrupted', () => {
    inTmpCwd((dir) => {
      fs.writeFileSync(path.join(dir, '.porter_history'), 'not json{{{');
      assert.strictEqual(StateManager.loadProgress('myfile.txt'), 0);
    });
  });

  test('preserves entries for multiple keys across saveProgress calls', () => {
    inTmpCwd(() => {
      StateManager.saveProgress('a.txt', 3);
      StateManager.saveProgress('b.txt', 7);
      StateManager.saveProgress('a.txt', 4);

      assert.strictEqual(StateManager.loadProgress('a.txt'), 4);
      assert.strictEqual(StateManager.loadProgress('b.txt'), 7);
      assert.strictEqual(StateManager.loadProgress('c.txt'), 0);
    });
  });
});
