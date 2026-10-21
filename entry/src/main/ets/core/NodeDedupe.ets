import { ProxyNode, XrayConfigType } from './Profile';
import { normalizeConfigInput } from './XrayConfig';

export function dedupeProxyNodes(nodes: Array<ProxyNode>): Array<ProxyNode> {
  const seen = new Set<string>();
  const result = new Array<ProxyNode>();
  for (let index = 0; index < nodes.length; index++) {
    const node = nodes[index];
    const key = proxyNodeDedupeKey(node);
    if (key.length > 0 && seen.has(key)) {
      continue;
    }
    if (key.length > 0) {
      seen.add(key);
    }
    result.push(node);
  }
  return result;
}

export function proxyNodeDedupeKey(node: ProxyNode): string {
  return proxyConfigDedupeKey(node.outboundJson, node.configType, node.rawLink);
}

export function proxyConfigDedupeKey(outboundJson: string, configType: XrayConfigType | undefined, rawLink: string = ''): string {
  if (isDedupeExcludedConfigType(configType)) {
    return '';
  }

  const validation = normalizeConfigInput(outboundJson, configType);
  if (validation.valid) {
    return `json:${normalizeOutboundDedupeJson(validation.normalizedJson)}`;
  }

  const normalizedRawLink = rawLink.trim();
  if (normalizedRawLink.length > 0) {
    return `raw:${normalizedRawLink}`;
  }
  return `json:${outboundJson.trim()}`;
}

export function isDedupeExcludedConfigType(configType: XrayConfigType | undefined): boolean {
  return configType === 'full' || configType === 'proxy-chain' || configType === 'policy-group';
}

function normalizeOutboundDedupeJson(normalizedJson: string): string {
  try {
    const parsed = JSON.parse(normalizedJson) as Record<string, Object>;
    const result: Record<string, Object> = {};
    const keys = Object.keys(parsed);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      if (key === 'tag' || key === 'remarks' || key === 'name') {
        continue;
      }
      result[key] = parsed[key];
    }
    return JSON.stringify(result);
  } catch (_error) {
    return normalizedJson;
  }
}
