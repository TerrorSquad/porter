export const FEATURE_BASE64 = process.env.PORTER_FEATURE_BASE64 !== 'false';
export const FEATURE_MULTI_PART_INPUT = process.env.PORTER_FEATURE_MULTI_PART_INPUT !== 'false';
export const FEATURE_INVERT = process.env.PORTER_FEATURE_INVERT !== 'false';
export const FEATURE_MULTI_QR = process.env.PORTER_FEATURE_MULTI_QR !== 'false';
export const FEATURE_INTERACTIVE_CONTROLS = process.env.PORTER_FEATURE_INTERACTIVE_CONTROLS !== 'false';
export const FEATURE_SERVE = process.env.PORTER_FEATURE_SERVE !== 'false';
export const FEATURE_JOIN = process.env.PORTER_FEATURE_JOIN !== 'false';

export const BUILD_FEATURES = {
  base64: FEATURE_BASE64,
  multiPartInput: FEATURE_MULTI_PART_INPUT,
  invert: FEATURE_INVERT,
  multiQr: FEATURE_MULTI_QR,
  interactiveControls: FEATURE_INTERACTIVE_CONTROLS,
  serve: FEATURE_SERVE,
  join: FEATURE_JOIN,
} as const;