// External text can arrive through QR, clipboard, share Want, deep link or a document
// picker. Keep parsing/N-API work bounded even when another app supplies an unexpectedly
// large payload. File imports use the same 2 MiB product limit at the byte boundary.
export const MAX_EXTERNAL_IMPORT_TEXT_CHARS: number = 2 * 1024 * 1024;
export const MAX_EXTERNAL_URI_CHARS: number = 8192;
export const IMPORT_TEXT_TOO_LARGE_MESSAGE: string = '导入内容超过 2 MB，请拆分后重试。';
export const SUBSCRIPTION_URL_TOO_LONG_MESSAGE: string = '订阅链接过长。';

export function isExternalImportTextTooLarge(value: string): boolean {
  return value.length > MAX_EXTERNAL_IMPORT_TEXT_CHARS;
}

export function isExternalUriTooLarge(value: string): boolean {
  return value.length > MAX_EXTERNAL_URI_CHARS;
}
