const SENSITIVE_URL_SCHEMES: Array<string> = [
  'https://',
  'http://',
  'vless://',
  'vmess://',
  'trojan://',
  'ss://',
  'ssr://',
  'hysteria://',
  'hysteria2://',
  'hy2://',
  'tuic://',
  'wireguard://',
  'wg://'
];

const SENSITIVE_VALUE_MARKERS: Array<string> = [
  '"password":"',
  '"token":"',
  '"uuid":"',
  '"id":"',
  'password=',
  'token=',
  'authorization=',
  'authorization:'
];

const REDACTED_URL: string = '[redacted-url]';
const REDACTED_VALUE: string = '[redacted]';

// Diagnostic records can be exported or copied for troubleshooting. Keep useful
// status/error context while removing credentials and complete private URLs.
export function redactDiagnosticText(value: string): string {
  let redacted = redactUrls(value);
  for (let index = 0; index < SENSITIVE_VALUE_MARKERS.length; index++) {
    redacted = redactMarkedValues(redacted, SENSITIVE_VALUE_MARKERS[index]);
  }
  redacted = redactUuidCredentials(redacted);
  redacted = redactHostPortEndpoints(redacted);
  redacted = redactIpv6Addresses(redacted);
  return redactIpv4Addresses(redacted);
}

function redactUrls(value: string): string {
  let result = value;
  let lower = result.toLowerCase();
  let searchFrom = 0;
  while (searchFrom < result.length) {
    const match = findNextScheme(lower, searchFrom);
    if (match.index < 0) {
      break;
    }
    let end = match.index + match.scheme.length;
    while (end < result.length && !isUrlTerminator(result.charAt(end))) {
      end++;
    }
    result = `${result.substring(0, match.index)}${REDACTED_URL}${result.substring(end)}`;
    lower = result.toLowerCase();
    searchFrom = match.index + REDACTED_URL.length;
  }
  return result;
}

interface SchemeMatch {
  index: number;
  scheme: string;
}

function findNextScheme(lowerValue: string, searchFrom: number): SchemeMatch {
  let nextIndex = -1;
  let nextScheme = '';
  for (let index = 0; index < SENSITIVE_URL_SCHEMES.length; index++) {
    const scheme = SENSITIVE_URL_SCHEMES[index];
    const position = lowerValue.indexOf(scheme, searchFrom);
    if (position >= 0 && (nextIndex < 0 || position < nextIndex)) {
      nextIndex = position;
      nextScheme = scheme;
    }
  }
  return { index: nextIndex, scheme: nextScheme };
}

function isUrlTerminator(character: string): boolean {
  return character === ' ' || character === '\t' || character === '\r' || character === '\n' ||
    character === '"' || character === "'" || character === '<' || character === '>' ||
    character === ')' || character === ']' || character === '}';
}

function redactMarkedValues(value: string, marker: string): string {
  let result = value;
  let lower = result.toLowerCase();
  let searchFrom = 0;
  while (searchFrom < result.length) {
    const markerIndex = lower.indexOf(marker, searchFrom);
    if (markerIndex < 0) {
      break;
    }
    const valueStart = markerIndex + marker.length;
    let valueEnd = valueStart;
    while (valueEnd < result.length && !isValueTerminator(result.charAt(valueEnd))) {
      valueEnd++;
    }
    result = `${result.substring(0, valueStart)}${REDACTED_VALUE}${result.substring(valueEnd)}`;
    lower = result.toLowerCase();
    searchFrom = valueStart + REDACTED_VALUE.length;
  }
  return result;
}

function isValueTerminator(character: string): boolean {
  return character === ' ' || character === '\t' || character === '\r' || character === '\n' ||
    character === '"' || character === "'" || character === '&' || character === ';' ||
    character === ',' || character === '}';
}

function redactUuidCredentials(value: string): string {
  let result = '';
  let index = 0;
  while (index < value.length) {
    if (isUuidAt(value, index)) {
      result += REDACTED_VALUE;
      index += 36;
    } else {
      result += value.charAt(index);
      index++;
    }
  }
  return result;
}

function isUuidAt(value: string, start: number): boolean {
  if (start + 36 > value.length) {
    return false;
  }
  for (let offset = 0; offset < 36; offset++) {
    const character = value.charAt(start + offset);
    if (offset === 8 || offset === 13 || offset === 18 || offset === 23) {
      if (character !== '-') {
        return false;
      }
    } else if (!isHexCharacter(character)) {
      return false;
    }
  }
  return true;
}

function isHexCharacter(character: string): boolean {
  const code = character.charCodeAt(0);
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 70) || (code >= 97 && code <= 102);
}

function redactHostPortEndpoints(value: string): string {
  let result = '';
  let index = 0;
  while (index < value.length) {
    const end = hostPortEnd(value, index);
    if (end > index) {
      const colon = value.lastIndexOf(':', end - 1);
      result += `[redacted-host]${value.substring(colon, end)}`;
      index = end;
    } else {
      result += value.charAt(index);
      index++;
    }
  }
  return result;
}

function hostPortEnd(value: string, start: number): number {
  if (start > 0 && isHostCharacter(value.charAt(start - 1))) {
    return -1;
  }
  let colon = start;
  while (colon < value.length && isHostCharacter(value.charAt(colon))) {
    colon++;
  }
  if (colon <= start || colon >= value.length || value.charAt(colon) !== ':') {
    return -1;
  }
  const host = value.substring(start, colon);
  if (host.indexOf('.') < 0 || host.startsWith('.') || host.endsWith('.')) {
    return -1;
  }
  let end = colon + 1;
  while (end < value.length && isDigit(value.charAt(end))) {
    end++;
  }
  if (end === colon + 1 || (end < value.length && isHostCharacter(value.charAt(end)))) {
    return -1;
  }
  const port = Number(value.substring(colon + 1, end));
  return port >= 1 && port <= 65535 ? end : -1;
}

function isHostCharacter(character: string): boolean {
  const code = character.charCodeAt(0);
  return isDigit(character) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
    character === '.' || character === '-';
}

function redactIpv4Addresses(value: string): string {
  let result = '';
  let index = 0;
  while (index < value.length) {
    const end = ipv4End(value, index);
    if (end > index) {
      result += '[redacted-ip]';
      index = end;
    } else {
      result += value.charAt(index);
      index++;
    }
  }
  return result;
}

function redactIpv6Addresses(value: string): string {
  let result = '';
  let index = 0;
  while (index < value.length) {
    if (value.charAt(index) === '[') {
      const close = value.indexOf(']', index + 1);
      if (close > index && looksLikeIpv6(value.substring(index + 1, close))) {
        result += '[redacted-ip]';
        index = close + 1;
        continue;
      }
    }
    if (index === 0 || !isIpv6TokenCharacter(value.charAt(index - 1))) {
      let end = index;
      while (end < value.length && isIpv6TokenCharacter(value.charAt(end))) {
        end++;
      }
      if (end > index && looksLikeIpv6(value.substring(index, end))) {
        result += '[redacted-ip]';
        index = end;
        continue;
      }
    }
    result += value.charAt(index);
    index++;
  }
  return result;
}

function looksLikeIpv6(value: string): boolean {
  let colonCount = 0;
  let hasHex = false;
  for (let index = 0; index < value.length; index++) {
    const character = value.charAt(index);
    if (character === ':') {
      colonCount++;
    } else if (isHexCharacter(character)) {
      hasHex = true;
    }
  }
  return hasHex && (value.indexOf('::') >= 0 || colonCount >= 4);
}

function isIpv6TokenCharacter(character: string): boolean {
  return isHexCharacter(character) || character === ':' || character === '.' || character === '%';
}

function ipv4End(value: string, start: number): number {
  if (start > 0 && (isDigit(value.charAt(start - 1)) || value.charAt(start - 1) === '.')) {
    return -1;
  }
  let cursor = start;
  for (let part = 0; part < 4; part++) {
    const numberStart = cursor;
    while (cursor < value.length && isDigit(value.charAt(cursor)) && cursor - numberStart < 3) {
      cursor++;
    }
    if (cursor === numberStart || Number(value.substring(numberStart, cursor)) > 255) {
      return -1;
    }
    if (part < 3) {
      if (cursor >= value.length || value.charAt(cursor) !== '.') {
        return -1;
      }
      cursor++;
    }
  }
  if (cursor < value.length && (isDigit(value.charAt(cursor)) || value.charAt(cursor) === '.')) {
    return -1;
  }
  return cursor;
}

function isDigit(character: string): boolean {
  const code = character.charCodeAt(0);
  return code >= 48 && code <= 57;
}
