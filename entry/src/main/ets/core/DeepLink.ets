// Deep-link (URL Scheme / Want) intents for import entry points plus
// shortcut/automation controls. The app registers the scheme
//   hey://add-source?url=<encoded remote config source url>
//   hey://add-endpoint?url=<encoded share link>
//   hey://control?action=start|stop|toggle|scan[&guid=<node id>]
//   hey://start | hey://stop | hey://toggle | hey://scan[?guid=<node id>]
// EntryAbility stashes the raw Want uri or shortcut parameters; the Index page
// parses and handles it.

import { isExternalImportTextTooLarge } from './ExternalInput';

export type DeepLinkKind = 'sub' | 'config' | 'control' | 'none';
export type DeepLinkControlAction = 'start' | 'stop' | 'toggle' | 'scan' | '';

export const CONTROL_SHORTCUT_ACTION_PARAM: string = 'hey.control.action';
export const CONTROL_SHORTCUT_URI_PARAM: string = 'hey.control.uri';
export const CONTROL_SHORTCUT_NODE_ID_PARAM: string = 'hey.control.nodeId';
export const CONTROL_SHORTCUT_GUID_PARAM: string = 'hey.control.guid';
export const TASKER_EXTRA_BUNDLE_SWITCH_PARAM: string = 'tasker_extra_bundle_switch';
export const TASKER_EXTRA_BUNDLE_GUID_PARAM: string = 'tasker_extra_bundle_guid';

export interface DeepLinkWantLike {
  uri?: string;
  parameters?: Record<string, Object>;
}

export interface DeepLinkIntent {
  kind: DeepLinkKind;
  payload: string;
  action?: DeepLinkControlAction;
  targetNodeId?: string;
}

const CONTROL_PREFIX: string = 'hey://control';

export function parseDeepLink(uri: string): DeepLinkIntent {
  if (isExternalImportTextTooLarge(uri)) {
    return { kind: 'none', payload: '' };
  }
  const trimmed = uri.trim();
  if (trimmed.length === 0) {
    return { kind: 'none', payload: '' };
  }
  const lower = trimmed.toLowerCase();
  if (isShortcutHost(lower, 'add-source')) {
    return buildIntent('sub', trimmed);
  }
  if (isShortcutHost(lower, 'add-endpoint')) {
    return buildIntent('config', trimmed);
  }
  if (isShortcutHost(lower, 'control')) {
    return buildControlIntent(trimmed);
  }
  const action = controlActionFromShortcutHost(lower);
  if (action.length > 0) {
    return { kind: 'control', payload: action, action, targetNodeId: extractControlTargetNodeId(trimmed) };
  }
  return { kind: 'none', payload: '' };
}

export function deepLinkUriFromWant(want: DeepLinkWantLike): string {
  const uri = (want.uri ?? '').trim();
  if (uri.length > 0) {
    return uri;
  }
  return controlUriFromShortcutParameters(want.parameters);
}

export function controlUriFromShortcutParameters(parameters: Record<string, Object> | undefined): string {
  if (parameters === undefined) {
    return '';
  }
  const directUri = parameterText(parameters[CONTROL_SHORTCUT_URI_PARAM]);
  if (directUri.length > 0 && parseDeepLink(directUri).kind !== 'none') {
    return directUri;
  }
  const action = controlActionFromShortcutParameters(parameters);
  if (action.length > 0) {
    return appendControlTarget(`hey://control?action=${action}`, controlTargetNodeIdFromShortcutParameters(parameters));
  }
  return '';
}

function buildIntent(kind: DeepLinkKind, uri: string): DeepLinkIntent {
  const payload = withOuterFragmentFallback(extractUrlParam(uri), extractOuterFragment(uri));
  if (payload.length === 0) {
    return { kind: 'none', payload: '' };
  }
  return { kind, payload };
}

function buildControlIntent(uri: string): DeepLinkIntent {
  const queryAction = normalizeControlAction(extractQueryParam(uri, 'action'));
  const targetNodeId = extractControlTargetNodeId(uri);
  if (queryAction.length > 0) {
    return { kind: 'control', payload: queryAction, action: queryAction, targetNodeId };
  }

  const pathAction = normalizeControlAction(extractControlPath(uri));
  if (pathAction.length > 0) {
    return { kind: 'control', payload: pathAction, action: pathAction, targetNodeId };
  }
  return { kind: 'none', payload: '' };
}

function extractUrlParam(uri: string): string {
  return extractQueryParam(uri, 'url');
}

function extractQueryParam(uri: string, key: string): string {
  const queryStart = uri.indexOf('?');
  if (queryStart < 0) {
    return '';
  }
  const fragmentStart = uri.indexOf('#', queryStart + 1);
  const queryEnd = fragmentStart >= 0 ? fragmentStart : uri.length;
  const query = uri.substring(queryStart + 1, queryEnd);
  const pairs = query.split('&');
  for (let index = 0; index < pairs.length; index++) {
    const pair = pairs[index];
    const eq = pair.indexOf('=');
    if (eq > 0 && pair.substring(0, eq) === key) {
      const raw = pair.substring(eq + 1);
      try {
        return decodeURIComponent(raw);
      } catch (error) {
        return raw;
      }
    }
  }
  return '';
}

function extractControlTargetNodeId(uri: string): string {
  const keys = ['guid', 'nodeId', 'nodeid', 'id', 'node'];
  for (let index = 0; index < keys.length; index++) {
    const value = extractQueryParam(uri, keys[index]).trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

function controlTargetNodeIdFromShortcutParameters(parameters: Record<string, Object>): string {
  const guid = parameterText(parameters[CONTROL_SHORTCUT_GUID_PARAM]);
  if (guid.length > 0) {
    return guid;
  }
  const nodeId = parameterText(parameters[CONTROL_SHORTCUT_NODE_ID_PARAM]);
  if (nodeId.length > 0) {
    return nodeId;
  }
  return parameterText(parameters[TASKER_EXTRA_BUNDLE_GUID_PARAM]);
}

function controlActionFromShortcutParameters(parameters: Record<string, Object>): DeepLinkControlAction {
  const action = normalizeControlAction(parameterText(parameters[CONTROL_SHORTCUT_ACTION_PARAM]));
  if (action.length > 0) {
    return action;
  }
  return controlActionFromTaskerSwitch(parameters[TASKER_EXTRA_BUNDLE_SWITCH_PARAM]);
}

function controlActionFromTaskerSwitch(value: Object | undefined): DeepLinkControlAction {
  const text = parameterText(value).toLowerCase();
  if (text === 'true' || text === '1') {
    return 'start';
  }
  if (text === 'false' || text === '0') {
    return 'stop';
  }
  return '';
}

function appendControlTarget(uri: string, targetNodeId: string): string {
  const target = targetNodeId.trim();
  if (target.length === 0) {
    return uri;
  }
  return `${uri}&guid=${encodeURIComponent(target)}`;
}

function extractOuterFragment(uri: string): string {
  const queryStart = uri.indexOf('?');
  const fragmentStart = uri.indexOf('#', queryStart >= 0 ? queryStart + 1 : 0);
  if (fragmentStart < 0) {
    return '';
  }
  const raw = uri.substring(fragmentStart + 1);
  try {
    return decodeURIComponent(raw);
  } catch (error) {
    return raw;
  }
}

function withOuterFragmentFallback(payload: string, outerFragment: string): string {
  if (payload.length === 0 || outerFragment.length === 0 || payloadFragment(payload).length > 0) {
    return payload;
  }
  return `${payload}#${outerFragment}`;
}

function payloadFragment(payload: string): string {
  const fragmentStart = payload.indexOf('#');
  if (fragmentStart < 0) {
    return '';
  }
  return payload.substring(fragmentStart + 1);
}

function extractControlPath(uri: string): string {
  const lower = uri.toLowerCase();
  if (!lower.startsWith(CONTROL_PREFIX)) {
    return '';
  }
  const afterPrefix = uri.substring(CONTROL_PREFIX.length);
  if (!afterPrefix.startsWith('/')) {
    return '';
  }
  const queryStart = afterPrefix.indexOf('?');
  const path = queryStart >= 0 ? afterPrefix.substring(0, queryStart) : afterPrefix;
  return path.replace('/', '');
}

function controlActionFromShortcutHost(lowerUri: string): DeepLinkControlAction {
  if (isShortcutHost(lowerUri, 'start')) {
    return 'start';
  }
  if (isShortcutHost(lowerUri, 'stop')) {
    return 'stop';
  }
  if (isShortcutHost(lowerUri, 'toggle') || isShortcutHost(lowerUri, 'switch')) {
    return 'toggle';
  }
  if (isShortcutHost(lowerUri, 'scan')) {
    return 'scan';
  }
  return '';
}

function isShortcutHost(lowerUri: string, host: string): boolean {
  const prefix = `hey://${host}`;
  return lowerUri === prefix || lowerUri.startsWith(`${prefix}?`) || lowerUri.startsWith(`${prefix}/`);
}

function normalizeControlAction(value: string): DeepLinkControlAction {
  const normalized = value.trim().toLowerCase();
  if (normalized === 'start' || normalized === 'stop' || normalized === 'scan') {
    return normalized;
  }
  if (normalized === 'toggle' || normalized === 'switch') {
    return 'toggle';
  }
  return '';
}

function parameterText(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value.trim();
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return value.toString().trim();
  }
  return '';
}

export function subscriptionNameFromDeepLink(url: string): string {
  const trimmed = url.trim();
  const schemeEnd = trimmed.indexOf('://');
  const authorityStart = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  let authorityEnd = trimmed.length;
  const separators = ['/', '?', '#'];
  for (let index = 0; index < separators.length; index++) {
    const separatorIndex = trimmed.indexOf(separators[index], authorityStart);
    if (separatorIndex >= 0 && separatorIndex < authorityEnd) {
      authorityEnd = separatorIndex;
    }
  }
  let authority = trimmed.substring(authorityStart, authorityEnd);
  const userInfoEnd = authority.lastIndexOf('@');
  if (userInfoEnd >= 0) {
    authority = authority.substring(userInfoEnd + 1);
  }
  if (authority.startsWith('[')) {
    const bracketEnd = authority.indexOf(']');
    const ipv6Host = bracketEnd > 0 ? authority.substring(1, bracketEnd) : '';
    return ipv6Host.length > 0 ? ipv6Host : 'Subscription';
  }
  const portSeparator = authority.lastIndexOf(':');
  const host = portSeparator > 0 && authority.indexOf(':') === portSeparator ?
    authority.substring(0, portSeparator) : authority;
  return host.length > 0 ? host : 'Subscription';
}
