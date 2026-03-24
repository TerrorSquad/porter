import { builtinModules } from 'node:module';
import commonjs from '@rollup/plugin-commonjs';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import replace from '@rollup/plugin-replace';
import terser from '@rollup/plugin-terser';
import typescript from '@rollup/plugin-typescript';

const externalDeps = (process.env.EXTERNAL_DEPS ?? '')
  .split(',')
  .map(entry => entry.trim())
  .filter(Boolean);
const outputFile = process.env.OUTPUT_FILE ?? 'dist/porter.mjs';

const externalModules = new Set([
  ...builtinModules,
  ...builtinModules.map(moduleName => `node:${moduleName}`),
  ...externalDeps,
]);

function isExternal(id) {
  if (externalModules.has(id)) {
    return true;
  }

  return externalDeps.some(dependency => id === dependency || id.startsWith(`${dependency}/`));
}

export default {
  input: 'src/porter.ts',
  output: {
    file: outputFile,
    format: 'esm',
    inlineDynamicImports: true,
  },
  external: isExternal,
  plugins: [
    replace({
      preventAssignment: true,
      values: {
        'process.env.PORTER_FEATURE_BASE64': '"true"',
        'process.env.PORTER_FEATURE_MULTI_PART_INPUT': '"true"',
        'process.env.PORTER_FEATURE_INVERT': '"true"',
        'process.env.PORTER_FEATURE_MULTI_QR': '"true"',
        'process.env.PORTER_FEATURE_INTERACTIVE_CONTROLS': '"true"',
        'process.env.PORTER_FEATURE_SERVE': '"true"',
        'process.env.PORTER_FEATURE_JOIN': '"true"',
      },
    }),
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
    terser({
      compress: {
        passes: 2,
        pure_getters: true,
      },
      format: {
        comments: false,
      },
      mangle: true,
    }),
  ],
};