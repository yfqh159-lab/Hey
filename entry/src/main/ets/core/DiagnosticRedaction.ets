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
  return redactUuidCredentials(redacted);
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
