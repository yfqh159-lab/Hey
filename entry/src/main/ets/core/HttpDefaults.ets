// 应用发起 HTTP 请求时统一使用的 User-Agent。
// 只声明本应用自身身份，不冒充任何第三方客户端。
export const APP_HTTP_USER_AGENT: string = 'Hey/1.3 (HarmonyOS)';

// User-visible verification endpoints must be authenticated HTTPS URLs. Keep this
// helper free of NetworkKit dependencies so storage/import normalization can share the
// same boundary as the request path.
export function normalizeHttpsUrl(value: string): string {
  const target = value.trim();
  const prefix = 'https://';
  if (!target.toLowerCase().startsWith(prefix)) {
    return '';
  }
  const remainder = target.substring(prefix.length);
  if (remainder.length === 0 || /\s/.test(remainder)) {
    return '';
  }
  let authorityEnd = remainder.length;
  const separators = ['/', '?', '#'];
  for (let separatorIndex = 0; separatorIndex < separators.length; separatorIndex++) {
    const index = remainder.indexOf(separators[separatorIndex]);
    if (index >= 0 && index < authorityEnd) {
      authorityEnd = index;
    }
  }
  const authority = remainder.substring(0, authorityEnd);
  if (authority.length === 0 || authority === ':' || authority.startsWith(':') || authority.includes('@')) {
    return '';
  }
  // Canonicalize the scheme so downstream prefix checks cannot misclassify an uppercase
  // HTTPS URL and accidentally apply a weaker redirect policy.
  return `${prefix}${remainder}`;
}
