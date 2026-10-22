// Bounds for remotely supplied subscription metadata and node collections.
// These limits keep one malformed source from monopolising the ArkTS event loop or
// overflowing the Preferences record that stores all groups.
export const MAX_SUBSCRIPTION_GROUP_COUNT: number = 128;
export const MAX_SUBSCRIPTION_NODE_COUNT: number = 4096;
export const MAX_SUBSCRIPTION_NODE_INPUT_CHARS: number = 256 * 1024;
export const MAX_STORED_NODE_CONFIG_CHARS: number = 2 * 1024 * 1024;
export const MAX_SUBSCRIPTION_NAME_CHARS: number = 512;
export const MAX_SUBSCRIPTION_GROUP_NAME_CHARS: number = 256;
export const MAX_SUBSCRIPTION_USER_AGENT_CHARS: number = 512;
export const MAX_SUBSCRIPTION_FILTER_CHARS: number = 256;
export const MAX_SUBSCRIPTION_PROFILE_NOTE_CHARS: number = 256;

export function limitSubscriptionText(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : value.substring(0, maxChars);
}

// JavaScript regular expressions run synchronously and cannot be cancelled. Bound both
// pattern and subject lengths, and reject the most common exponential-time constructs:
// quantified groups and backreferences. Ordinary filters such as "HK|US", "^(香港|日本)$"
// and character classes remain available.
export function isSafeSubscriptionFilterPattern(pattern: string): boolean {
  if (pattern.length === 0) {
    return true;
  }
  if (pattern.length > MAX_SUBSCRIPTION_FILTER_CHARS || /\\[1-9]/.test(pattern)) {
    return false;
  }
  if (/\)[*+{]/.test(pattern)) {
    return false;
  }
  try {
    new RegExp(pattern);
    return true;
  } catch (_error) {
    return false;
  }
}
