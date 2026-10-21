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

const SENSITIVE_JSON_FIELDS: Array<string> = [
  'password',
  'pass',
  'token',
  'authorization',
  'uuid',
  'id',
  'secretkey',
  'privatekey',
  'presharedkey',
  'private_key',
  'pre_shared_key'
];

const SENSITIVE_ASSIGNMENT_KEYS: Array<string> = [
  'password',
  'pass',
  'token',
  'authorization',
  'uuid',
  'secretkey',
  'privatekey',
  'presharedkey',
  'private_key',
  'pre_shared_key'
];

const REDACTED_URL: string = '[redacted-url]';
const REDACTED_VALUE: string = '[redacted]';

// Diagnostic records can be exported or copied for troubleshooting. Keep useful
// status/error context while removing credentials and complete private URLs.
export function redactDiagnosticText(value: string): string {
  let redacted = redactUrls(value);
  for (let index = 0; index < SENSITIVE_JSON_FIELDS.length; index++) {
    redacted = redactJsonField(redacted, SENSITIVE_JSON_FIELDS[index]);
  }
  for (let index = 0; index < SENSITIVE_ASSIGNMENT_KEYS.length; index++) {
    redacted = redactAssignment(redacted, SENSITIVE_ASSIGNMENT_KEYS[index]);
  }
  redacted = redactAuthorizationHeader(redacted);
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

function redactJsonField(value: string, field: string): string {
  let result = value;
  let lower = result.toLowerCase();
  let searchFrom = 0;
  const marker = `"${field.toLowerCase()}"`;
  while (searchFrom < result.length) {
    const markerIndex = lower.indexOf(marker, searchFrom);
    if (markerIndex < 0) {
      break;
    }
    let cursor = skipWhitespace(result, markerIndex + marker.length);
    if (cursor >= result.length || result.charAt(cursor) !== ':') {
      searchFrom = markerIndex + marker.length;
      continue;
    }
    cursor = skipWhitespace(result, cursor + 1);
    const quoted = cursor < result.length && result.charAt(cursor) === '"';
    const valueStart = quoted ? cursor + 1 : cursor;
    const valueEnd = quoted ? quotedValueEnd(result, valueStart) : unquotedValueEnd(result, valueStart);
    result = `${result.substring(0, valueStart)}${REDACTED_VALUE}${result.substring(valueEnd)}`;
    lower = result.toLowerCase();
    searchFrom = valueStart + REDACTED_VALUE.length;
  }
  return result;
}

function redactAssignment(value: string, key: string): string {
  let result = value;
  let lower = result.toLowerCase();
  let searchFrom = 0;
  while (searchFrom < result.length) {
    const keyIndex = lower.indexOf(key, searchFrom);
    if (keyIndex < 0) {
      break;
    }
    if (!isAssignmentBoundary(result, keyIndex, key.length)) {
      searchFrom = keyIndex + key.length;
      continue;
    }
    let cursor = skipWhitespace(result, keyIndex + key.length);
    if (cursor >= result.length || result.charAt(cursor) !== '=') {
      searchFrom = keyIndex + key.length;
      continue;
    }
    cursor = skipWhitespace(result, cursor + 1);
    const quoted = cursor < result.length && (result.charAt(cursor) === '"' || result.charAt(cursor) === "'");
    const quote = quoted ? result.charAt(cursor) : '';
    const valueStart = quoted ? cursor + 1 : cursor;
    const valueEnd = quoted ? quotedValueEnd(result, valueStart, quote) :
      (key === 'authorization' ? authorizationValueEnd(result, valueStart) : unquotedValueEnd(result, valueStart));
    result = `${result.substring(0, valueStart)}${REDACTED_VALUE}${result.substring(valueEnd)}`;
    lower = result.toLowerCase();
    searchFrom = valueStart + REDACTED_VALUE.length;
  }
  return result;
}

function redactAuthorizationHeader(value: string): string {
  let result = value;
  let lower = result.toLowerCase();
  let searchFrom = 0;
  const marker = 'authorization';
  while (searchFrom < result.length) {
    const markerIndex = lower.indexOf(marker, searchFrom);
    if (markerIndex < 0) {
      break;
    }
    if (!isAssignmentBoundary(result, markerIndex, marker.length)) {
      searchFrom = markerIndex + marker.length;
      continue;
    }
    let cursor = skipWhitespace(result, markerIndex + marker.length);
    if (cursor >= result.length || result.charAt(cursor) !== ':') {
      searchFrom = markerIndex + marker.length;
      continue;
    }
    const valueStart = skipWhitespace(result, cursor + 1);
    let valueEnd = valueStart;
    while (valueEnd < result.length && result.charAt(valueEnd) !== '\r' && result.charAt(valueEnd) !== '\n' &&
      result.charAt(valueEnd) !== ',' && result.charAt(valueEnd) !== ';') {
      valueEnd++;
    }
    result = `${result.substring(0, valueStart)}${REDACTED_VALUE}${result.substring(valueEnd)}`;
    lower = result.toLowerCase();
    searchFrom = valueStart + REDACTED_VALUE.length;
  }
  return result;
}

function skipWhitespace(value: string, start: number): number {
  let cursor = start;
  while (cursor < value.length && (value.charAt(cursor) === ' ' || value.charAt(cursor) === '\t' ||
    value.charAt(cursor) === '\r' || value.charAt(cursor) === '\n')) {
    cursor++;
  }
  return cursor;
}

function isAssignmentBoundary(value: string, start: number, length: number): boolean {
  const before = start > 0 ? value.charAt(start - 1) : '';
  const afterIndex = start + length;
  const after = afterIndex < value.length ? value.charAt(afterIndex) : '';
  return !isNameCharacter(before) && !isNameCharacter(after);
}

function isNameCharacter(character: string): boolean {
  if (character.length === 0) {
    return false;
  }
  const code = character.charCodeAt(0);
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
    character === '_' || character === '-';
}

function quotedValueEnd(value: string, start: number, quote: string = '"'): number {
  let cursor = start;
  let escaped = false;
  while (cursor < value.length) {
    const character = value.charAt(cursor);
    if (!escaped && character === quote) {
      return cursor;
    }
    if (!escaped && character === '\\') {
      escaped = true;
    } else {
      escaped = false;
    }
    cursor++;
  }
  return cursor;
}

function unquotedValueEnd(value: string, start: number): number {
  let cursor = start;
  while (cursor < value.length && !isValueTerminator(value.charAt(cursor))) {
    cursor++;
  }
  return cursor;
}

function authorizationValueEnd(value: string, start: number): number {
  let cursor = start;
  while (cursor < value.length && value.charAt(cursor) !== '\r' && value.charAt(cursor) !== '\n' &&
    value.charAt(cursor) !== '&' && value.charAt(cursor) !== ',' && value.charAt(cursor) !== ';') {
    cursor++;
  }
  return cursor;
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
