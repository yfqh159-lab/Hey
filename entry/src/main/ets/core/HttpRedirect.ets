/**
 * Extracts Location from Network Kit's JSON-serialized response headers.
 * Header values may be strings or arrays and JSON escapes must be decoded before use.
 */
export function parseHttpRedirectLocation(headerJson: string): string {
  const match = headerJson.match(/"(?:Location|location)"\s*:\s*(?:"((?:\\.|[^"\\])*)"|\[\s*"((?:\\.|[^"\\])*)")/);
  if (match === null) {
    return '';
  }
  const encoded = match[1] ?? match[2] ?? '';
  if (encoded.length === 0) {
    return '';
  }
  try {
    return JSON.parse(`"${encoded}"`) as string;
  } catch (_error) {
    return '';
  }
}

/**
 * Resolves an HTTP Location value against the response URL that produced it.
 * This intentionally returns an empty string for non-HTTP bases and non-HTTP
 * absolute schemes; callers still apply their own host, TLS and credential policy.
 */
export function resolveHttpRedirectUrl(currentUrl: string, location: string): string {
  const base = currentUrl.trim();
  const target = location.trim();
  if (target.length === 0 || !isHttpUrl(base)) {
    return '';
  }
  if (isHttpUrl(target)) {
    return target;
  }

  const schemeEnd = base.indexOf('://');
  const scheme = base.substring(0, schemeEnd).toLowerCase();
  if (target.startsWith('//')) {
    return `${scheme}:${target}`;
  }
  if (hasAbsoluteScheme(target)) {
    return '';
  }

  const authorityStart = schemeEnd + 3;
  const authorityEnd = firstDelimiter(base, authorityStart);
  const origin = authorityEnd < 0 ? base : base.substring(0, authorityEnd);
  if (origin.length <= authorityStart) {
    return '';
  }

  const baseSuffix = authorityEnd < 0 ? '/' : base.substring(authorityEnd);
  const baseFragmentStart = baseSuffix.indexOf('#');
  const withoutFragment = baseFragmentStart < 0 ? baseSuffix : baseSuffix.substring(0, baseFragmentStart);
  const baseQueryStart = withoutFragment.indexOf('?');
  const basePath = baseQueryStart < 0 ? withoutFragment : withoutFragment.substring(0, baseQueryStart);
  if (target.startsWith('#')) {
    return `${origin}${withoutFragment}${target}`;
  }
  if (target.startsWith('?')) {
    return `${origin}${basePath.length > 0 ? basePath : '/'}${target}`;
  }

  const targetParts = splitPathSuffix(target);
  if (targetParts.path.startsWith('/')) {
    return `${origin}${normalizeHttpPath(targetParts.path)}${targetParts.suffix}`;
  }
  const normalizedBasePath = basePath.length > 0 ? basePath : '/';
  const lastSlash = normalizedBasePath.lastIndexOf('/');
  const baseDirectory = lastSlash < 0 ? '/' : normalizedBasePath.substring(0, lastSlash + 1);
  return `${origin}${normalizeHttpPath(`${baseDirectory}${targetParts.path}`)}${targetParts.suffix}`;
}

interface PathSuffix {
  path: string;
  suffix: string;
}

function splitPathSuffix(value: string): PathSuffix {
  const query = value.indexOf('?');
  const fragment = value.indexOf('#');
  let suffixStart = -1;
  if (query >= 0 && fragment >= 0) {
    suffixStart = Math.min(query, fragment);
  } else {
    suffixStart = Math.max(query, fragment);
  }
  if (suffixStart < 0) {
    return { path: value, suffix: '' };
  }
  return { path: value.substring(0, suffixStart), suffix: value.substring(suffixStart) };
}

function normalizeHttpPath(value: string): string {
  const segments = value.split('/');
  const normalized = new Array<string>();
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index];
    if (segment.length === 0 || segment === '.') {
      continue;
    }
    if (segment === '..') {
      if (normalized.length > 0) {
        normalized.pop();
      }
      continue;
    }
    normalized.push(segment);
  }
  let path = `/${normalized.join('/')}`;
  if (value.endsWith('/') && !path.endsWith('/')) {
    path += '/';
  }
  return path;
}

function isHttpUrl(value: string): boolean {
  const lower = value.toLowerCase();
  return lower.startsWith('https://') || lower.startsWith('http://');
}

function hasAbsoluteScheme(value: string): boolean {
  return /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value);
}

function firstDelimiter(value: string, start: number): number {
  let result = -1;
  const delimiters = ['/', '?', '#'];
  for (let index = 0; index < delimiters.length; index++) {
    const position = value.indexOf(delimiters[index], start);
    if (position >= 0 && (result < 0 || position < result)) {
      result = position;
    }
  }
  return result;
}
