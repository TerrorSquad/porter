import fs from 'fs';

const HIST_FILE = '.porter_history';

export class StateManager {
  public static saveProgress(fileKey: string, index: number) {
    let hist: Record<string, number> = {};
    if (fs.existsSync(HIST_FILE)) {
      try {
        hist = JSON.parse(fs.readFileSync(HIST_FILE, 'utf-8'));
      } catch (_e) {
        hist = {};
      }
    }
    hist[fileKey] = index;
    fs.writeFileSync(HIST_FILE, JSON.stringify(hist));
  }

  public static loadProgress(fileKey: string): number {
    if (fs.existsSync(HIST_FILE)) {
      try {
        const history: Record<string, number> = JSON.parse(fs.readFileSync(HIST_FILE, 'utf8'));
        if (typeof history[fileKey] === 'number') {
          return history[fileKey];
        }
      } catch (_e) {
        // ignore corruption
      }
    }
    return 0; // Default
  }
}
