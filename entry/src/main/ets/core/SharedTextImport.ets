import { MAX_EXTERNAL_IMPORT_TEXT_CHARS } from './ExternalInput';

export const HARMONY_SEND_DATA_ACTION: string = 'ohos.want.action.sendData';
export const HARMONY_TEXT_MIME_TYPE: string = 'text/plain';
export const HARMONY_CONTENT_TITLE_KEY: string = 'ohos.extra.param.key.contentTitle';
export const HARMONY_SHARE_ABSTRACT_KEY: string = 'ohos.extra.param.key.shareAbstract';
export const HARMONY_SHARE_URL_KEY: string = 'ohos.extra.param.key.shareUrl';

export interface SharedTextWantLike {
  action?: string;
  type?: string;
  parameters?: Record<string, Object>;
}

const SHARED_TEXT_PARAMETER_KEYS: Array<string> = [
  HARMONY_SHARE_URL_KEY,
  HARMONY_SHARE_ABSTRACT_KEY,
  'android.intent.extra.TEXT',
  'android.intent.extra.SUBJECT',
  'text',
  'content',
  'url',
  'shareUrl',
  HARMONY_CONTENT_TITLE_KEY
];

export function isSharedTextWant(want: SharedTextWantLike): boolean {
  const action = (want.action ?? '').trim().toLowerCase();
  if (action !== HARMONY_SEND_DATA_ACTION.toLowerCase()) {
    return false;
  }
  return isTextMimeType(want.type);
}

export function extractSharedTextFromWant(want: SharedTextWantLike): string {
  if (!isSharedTextWant(want)) {
    return '';
  }
  const parameters = want.parameters;
  if (parameters === undefined) {
    return '';
  }
  for (let index = 0; index < SHARED_TEXT_PARAMETER_KEYS.length; index++) {
    const value = sharedTextValue(parameters[SHARED_TEXT_PARAMETER_KEYS[index]]);
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

function isTextMimeType(type: string | undefined): boolean {
  const normalized = (type ?? '').trim().toLowerCase();
  return normalized === HARMONY_TEXT_MIME_TYPE || normalized.startsWith(`${HARMONY_TEXT_MIME_TYPE};`);
}

function sharedTextValue(value: Object | undefined, depth: number = 0): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return boundedSharedText(value);
  }
  if (Array.isArray(value)) {
    // Want parameters are untrusted runtime objects. Bound recursive array flattening so
    // deeply nested or extremely wide structures cannot exhaust the UI stack before the
    // ordinary external-text size check runs.
    if (depth >= 8) {
      return '';
    }
    const parts = new Array<string>();
    let totalLength = 0;
    const values = value as Array<Object>;
    const count = Math.min(values.length, 256);
    for (let index = 0; index < count; index++) {
      const text = sharedTextValue(values[index], depth + 1);
      if (text.length > 0) {
        totalLength += text.length + (parts.length > 0 ? 1 : 0);
        if (totalLength > MAX_EXTERNAL_IMPORT_TEXT_CHARS) {
          return oversizedSharedTextMarker();
        }
        parts.push(text);
      }
    }
    return parts.join('\n').trim();
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return value.toString().trim();
  }
  return '';
}

function boundedSharedText(value: string): string {
  if (value.length > MAX_EXTERNAL_IMPORT_TEXT_CHARS) {
    // Preserve the existing UI's "too large" classification without trimming or
    // retaining an arbitrarily large external Want value in AppStorage.
    return oversizedSharedTextMarker();
  }
  return value.trim();
}

function oversizedSharedTextMarker(): string {
  return 'x'.repeat(MAX_EXTERNAL_IMPORT_TEXT_CHARS + 1);
}
