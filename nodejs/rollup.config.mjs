import { builtinModules } from 'node:module';
import commonjs from '@rollup/plugin-commonjs';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import typescript from '@rollup/plugin-typescript';

const externalDeps = (process.env.EXTERNAL_DEPS ?? '')
  .split(',')
  .map(entry => entry.trim())
  .filter(Boolean);

const externalModules = new Set([
  ...builtinModules,
  ...builtinModules.map(moduleName => `node:${moduleName}`),
  ...externalDeps,
]);

const fixQrcodeTerminalEscapes = {
  name: 'fix-qrcode-terminal-escapes',
  transform(code, id) {
    if (!id.includes('/qrcode-terminal/lib/main.js')) {
      return null;
    }

    return {
      code: code.replace(/\\033/g, '\\x1b'),
      map: null,
    };
  },
};

function isExternal(id) {
  if (externalModules.has(id)) {
    return true;
  }

  return externalDeps.some(dependency => id === dependency || id.startsWith(`${dependency}/`));
}

export default {
  input: 'src/porter.ts',
  output: {
    compact: true,
    file: 'dist/porter.mjs',
    format: 'esm',
  },
  external: isExternal,
  plugins: [
    fixQrcodeTerminalEscapes,
    nodeResolve({
      extensions: ['.mjs', '.js', '.json', '.node', '.ts'],
      preferBuiltins: true,
    }),
    commonjs(),
    typescript({
      compilerOptions: {
        declaration: false,
        declarationMap: false,
      },
      tsconfig: './tsconfig.json',
    }),
  ],
};