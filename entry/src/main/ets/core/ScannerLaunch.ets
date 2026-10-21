export const SCANNER_START_IMMEDIATELY_PARAM: string = 'startImmediately';

export function shouldStartScannerImmediately(params: Record<string, Object> | undefined): boolean {
  if (params === undefined) {
    return false;
  }
  const value = params[SCANNER_START_IMMEDIATELY_PARAM];
  if (value === undefined || value === null) {
    return false;
  }
  const normalized = value.toString().trim().toLowerCase();
  return normalized === '1' || normalized === 'true';
}
