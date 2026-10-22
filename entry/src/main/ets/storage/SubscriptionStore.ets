import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ProxyNode, SubscriptionGroup, SubscriptionProfile, XrayConfigType } from '../core/Profile';
import { dedupeProxyNodes, proxyConfigDedupeKey, proxyNodeDedupeKey } from '../core/NodeDedupe';
import {
  DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES,
  moveSubscriptionGroup,
  normalizeSubscriptionUpdateInterval
} from '../core/SubscriptionGroups';
import { resolveGlobalSelectedNodeId, resolveRetainedSelectedNodeId } from '../core/SubscriptionSelection';
import { normalizeConfigInput } from '../core/XrayConfig';
import { subscriptionNameFromDeepLink } from '../core/DeepLink';
import {
  MAX_SUBSCRIPTION_FILTER_CHARS,
  MAX_SUBSCRIPTION_GROUP_COUNT,
  MAX_SUBSCRIPTION_GROUP_NAME_CHARS,
  MAX_SUBSCRIPTION_NAME_CHARS,
  MAX_SUBSCRIPTION_NODE_COUNT,
  MAX_SUBSCRIPTION_PROFILE_NOTE_CHARS,
  MAX_SUBSCRIPTION_USER_AGENT_CHARS,
  MAX_STORED_NODE_CONFIG_CHARS,
  limitSubscriptionText
} from '../core/SubscriptionSafety';

const PREFERENCES_NAME: string = 'hey_vpn_subscription';
const SUBSCRIPTION_KEY: string = 'subscription_profile';
const SUBSCRIPTION_BACKUP_KEY: string = 'subscription_profile_backup';

export interface ManualNodeUpdateResult {
  updated: boolean;
  selected: boolean;
  node: ProxyNode | null;
  profile: SubscriptionProfile;
}

export interface ManualNodeAddResult {
  added: boolean;
  duplicate: ProxyNode | null;
  profile: SubscriptionProfile;
}

// 批量延迟落库的单条更新。
export interface NodeDelayUpdate {
  nodeId: string;
  delayMs: number;
  delayStatus: string;
  delayTestAt: number;
}

export interface StoredSubscriptionSelection {
  profile: SubscriptionProfile | null;
  source: string;
}

export class SubscriptionStore {
  // Every public mutation below reads, modifies and writes the complete profile. Keep the
  // whole transaction in one process-wide queue; serializing only Preferences.put/flush
  // would still let two callers read the same old profile and lose whichever update saves first.
  private static mutationTail: Promise<void> = Promise.resolve();
  // Reads participate in a separate physical-storage queue so backup recovery cannot overwrite
  // a newer primary record while a queued mutation is saving it.
  private static storageTail: Promise<void> = Promise.resolve();

  static load(context: common.Context): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueStorage(async (): Promise<SubscriptionProfile> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const primaryRaw = (await store.get(SUBSCRIPTION_KEY, '')).toString();
      const backupRaw = (await store.get(SUBSCRIPTION_BACKUP_KEY, '')).toString();
      const selection = SubscriptionStore.selectStoredProfile(primaryRaw, backupRaw);
      if (selection.profile !== null && selection.source !== 'backup') {
        return selection.profile;
      }
      if (selection.profile !== null) {
        // 返回上一份完整数据优先于把损坏主副本当成空库。修复与正常保存共用存储队列，
        // 因此旧备份不会越过一个更新的主副本再把它覆盖。
        try {
          await store.put(SUBSCRIPTION_KEY, JSON.stringify(selection.profile));
          await store.flush();
        } catch (_error) {
          // keep recovered in-memory value
        }
        return selection.profile;
      }
      throw new Error('Stored node database is unreadable; the existing data was not overwritten.');
    });
  }

  static selectStoredProfile(primaryRaw: string, backupRaw: string): StoredSubscriptionSelection {
    if (primaryRaw.length === 0 && backupRaw.length === 0) {
      return { profile: SubscriptionStore.createEmpty(), source: 'empty' };
    }
    const primary = SubscriptionStore.parseStoredProfile(primaryRaw);
    if (primary !== null) {
      return { profile: primary, source: 'primary' };
    }
    const backup = SubscriptionStore.parseStoredProfile(backupRaw);
    if (backup !== null) {
      return { profile: backup, source: 'backup' };
    }
    return { profile: null, source: 'invalid' };
  }

  static saveUrl(context: common.Context, url: string, groupId?: string, touchUpdatedAt: boolean = true): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    let group: SubscriptionGroup | null = null;
    if (groupId && groupId.length > 0) {
      group = SubscriptionStore.findGroup(profile.groups, groupId);
    }
    if (group === null) {
      group = SubscriptionStore.activeGroup(profile);
    }
    if (group === null) {
      group = SubscriptionStore.createGroup(url, SubscriptionStore.nameFromUrl(url));
      profile.groups.push(group);
      profile.selectedGroupId = group.id;
    }
    group.url = url;
    if (group.name.length === 0 || group.name.startsWith('Subscription ')) {
      group.name = SubscriptionStore.nameFromUrl(url);
    }
    if (touchUpdatedAt) {
      group.updatedAt = Date.now();
    }
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static saveNodes(context: common.Context, groupId: string, url: string, nodes: Array<ProxyNode>, selectedNodeId: string, makeActive: boolean = true): Promise<SubscriptionProfile> {
    // Queue execution may start after the caller continues using its parsed array. Freeze the
    // payload at the API boundary so a later caller-side mutation cannot change this transaction.
    const nodesSnapshot = SubscriptionStore.normalizeNodes(nodes);
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    let group: SubscriptionGroup | null = null;
    if (groupId.length > 0) {
      group = SubscriptionStore.findGroup(profile.groups, groupId);
    }
    if (group === null) {
      group = SubscriptionStore.findGroupByUrl(profile.groups, url);
    }
    if (group === null) {
      group = SubscriptionStore.activeGroup(profile);
    }
    if (group === null) {
      group = SubscriptionStore.createGroup(url, SubscriptionStore.nameFromUrl(url));
      profile.groups.push(group);
    }

    const previousNodes = group.nodes;
    const mergedNodes = SubscriptionStore.mergeNodeRuntime(previousNodes, nodesSnapshot);
    const globalSelectedInThisGroup = profile.selectedNodeId.length > 0 &&
      SubscriptionStore.findNode(previousNodes, profile.selectedNodeId) !== null;
    group.url = url;
    group.nodes = mergedNodes;
    group.selectedNodeId = resolveRetainedSelectedNodeId(previousNodes, mergedNodes, selectedNodeId);
    // 全局当前节点属于本组时，让它跟随本组更新后的保留结果（节点可能被改名 / 重匹配 / 移除）。
    if (globalSelectedInThisGroup) {
      profile.selectedNodeId = group.selectedNodeId;
    }
    group.updatedAt = Date.now();
    if (makeActive) {
      profile.selectedGroupId = group.id;
    }
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static saveNodeDelay(context: common.Context, nodeId: string, delayMs: number, delayStatus: string, delayTestAt: number): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    for (let groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      const group = profile.groups[groupIndex];
      for (let nodeIndex = 0; nodeIndex < group.nodes.length; nodeIndex++) {
        if (group.nodes[nodeIndex].id === nodeId) {
          group.nodes[nodeIndex].delayMs = delayMs;
          group.nodes[nodeIndex].delayStatus = delayStatus;
          group.nodes[nodeIndex].delayTestAt = delayTestAt;
        }
      }
    }
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile), false);
    return SubscriptionStore.load(context);
    });
  }

  // 批量落库一组节点的延迟结果：一次 load/save 写完整块，避免逐节点反复读写
  // preferences（大列表分块测速时每块只写一次）。
  static saveNodeDelays(context: common.Context, updates: Array<NodeDelayUpdate>): Promise<SubscriptionProfile> {
    const updatesSnapshot = new Array<NodeDelayUpdate>();
    for (let index = 0; index < updates.length; index++) {
      updatesSnapshot.push({
        nodeId: updates[index].nodeId,
        delayMs: updates[index].delayMs,
        delayStatus: updates[index].delayStatus,
        delayTestAt: updates[index].delayTestAt
      });
    }
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const byId = new Map<string, NodeDelayUpdate>();
    for (let i = 0; i < updatesSnapshot.length; i++) {
      byId.set(updatesSnapshot[i].nodeId, updatesSnapshot[i]);
    }
    for (let groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      const group = profile.groups[groupIndex];
      for (let nodeIndex = 0; nodeIndex < group.nodes.length; nodeIndex++) {
        const update = byId.get(group.nodes[nodeIndex].id);
        if (update !== undefined) {
          group.nodes[nodeIndex].delayMs = update.delayMs;
          group.nodes[nodeIndex].delayStatus = update.delayStatus;
          group.nodes[nodeIndex].delayTestAt = update.delayTestAt;
        }
      }
    }
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile), false);
    return SubscriptionStore.load(context);
    });
  }

  static saveActiveGroupNodes(context: common.Context, nodes: Array<ProxyNode>, selectedNodeId: string): Promise<SubscriptionProfile> {
    const nodesSnapshot = SubscriptionStore.normalizeNodes(nodes);
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.activeGroup(profile);
    if (group !== null) {
      group.nodes = nodesSnapshot;
      group.selectedNodeId = SubscriptionStore.resolveSelectedNodeId(group.nodes, selectedNodeId);
      group.updatedAt = Date.now();
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static saveGroups(context: common.Context, groups: Array<SubscriptionGroup>): Promise<SubscriptionProfile> {
    const groupsSnapshot = SubscriptionStore.normalizeGroups(groups);
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    profile.groups = groupsSnapshot;
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  // 用整份订阅档案覆盖现有数据（配置恢复用）。normalize 负责字段归一化与容错。
  static restoreProfile(context: common.Context, profile: SubscriptionProfile): Promise<SubscriptionProfile> {
    const profileSnapshot = SubscriptionStore.normalize(profile);
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    await SubscriptionStore.save(context, profileSnapshot);
    return SubscriptionStore.load(context);
    });
  }

  static removeNode(context: common.Context, nodeId: string): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    let removed = false;
    for (let groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      const group = profile.groups[groupIndex];
      const nodes = new Array<ProxyNode>();
      for (let index = 0; index < group.nodes.length; index++) {
        if (group.nodes[index].id !== nodeId) {
          nodes.push(group.nodes[index]);
        }
      }
      if (nodes.length !== group.nodes.length) {
        group.nodes = nodes;
        group.selectedNodeId = SubscriptionStore.resolveSelectedNodeId(nodes, group.selectedNodeId);
        group.updatedAt = Date.now();
        removed = true;
      }
    }
    if (removed) {
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static removeInvalidNodes(context: common.Context): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.activeGroup(profile);
    if (group !== null) {
      const nodes = new Array<ProxyNode>();
      for (let index = 0; index < group.nodes.length; index++) {
        const node = group.nodes[index];
        if (normalizeConfigInput(node.outboundJson, node.configType).valid) {
          nodes.push(node);
        }
      }
      group.nodes = nodes;
      group.selectedNodeId = SubscriptionStore.resolveSelectedNodeId(nodes, group.selectedNodeId);
      group.updatedAt = Date.now();
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static dedupeActiveGroupNodes(context: common.Context): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.activeGroup(profile);
    if (group !== null) {
      group.nodes = SubscriptionStore.dedupeNodes(group.nodes);
      group.selectedNodeId = SubscriptionStore.resolveSelectedNodeId(group.nodes, group.selectedNodeId);
      group.updatedAt = Date.now();
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static clearActiveGroupNodes(context: common.Context): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.activeGroup(profile);
    if (group !== null) {
      group.nodes = [];
      group.selectedNodeId = '';
      group.updatedAt = Date.now();
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static selectNode(context: common.Context, selectedNodeId: string): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    for (let index = 0; index < profile.groups.length; index++) {
      const group = profile.groups[index];
      if (SubscriptionStore.findNode(group.nodes, selectedNodeId) !== null) {
        group.selectedNodeId = selectedNodeId;
        profile.selectedGroupId = group.id;
        // 全局当前节点：手动点选节点是唯一改变它的途径。
        profile.selectedNodeId = selectedNodeId;
        await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
        return SubscriptionStore.load(context);
      }
    }

    profile.selectedNodeId = selectedNodeId;
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static selectGroup(context: common.Context, groupId: string): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    if (SubscriptionStore.findGroup(profile.groups, groupId) !== null) {
      profile.selectedGroupId = groupId;
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static toggleGroup(context: common.Context, groupId: string): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.findGroup(profile.groups, groupId);
    if (group !== null) {
      group.enabled = !group.enabled;
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static removeGroup(context: common.Context, groupId: string): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const groups: Array<SubscriptionGroup> = [];
    for (let index = 0; index < profile.groups.length; index++) {
      if (profile.groups[index].id !== groupId) {
        groups.push(profile.groups[index]);
      }
    }
    profile.groups = groups;
    if (SubscriptionStore.findGroup(profile.groups, profile.selectedGroupId) === null) {
      profile.selectedGroupId = profile.groups.length > 0 ? profile.groups[0].id : '';
    }
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static moveGroup(context: common.Context, groupId: string, delta: number): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    profile.groups = moveSubscriptionGroup(profile.groups, groupId, delta);
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static addGroup(
    context: common.Context,
    name: string,
    url: string,
    userAgent: string = '',
    filter: string = '',
    prevProfile: string = '',
    nextProfile: string = '',
    allowInsecureUrl: boolean = false,
    autoUpdate: boolean = false,
    updateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
  ): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.createGroup(url, name, userAgent, filter, prevProfile, nextProfile, allowInsecureUrl, autoUpdate, updateIntervalMinutes);
    profile.groups.push(group);
    profile.selectedGroupId = group.id;
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
    });
  }

  static updateGroup(
    context: common.Context,
    groupId: string,
    name: string,
    url: string,
    userAgent: string = '',
    filter: string = '',
    prevProfile: string = '',
    nextProfile: string = '',
    allowInsecureUrl: boolean = false,
    autoUpdate: boolean = false,
    updateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
  ): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
    const profile = await SubscriptionStore.load(context);
    const group = SubscriptionStore.findGroup(profile.groups, groupId);
    if (group !== null) {
      group.name = name;
      group.url = url;
      group.userAgent = userAgent;
      group.filter = filter;
      group.prevProfile = prevProfile;
      group.nextProfile = nextProfile;
      group.allowInsecureUrl = allowInsecureUrl;
      group.autoUpdate = autoUpdate;
      group.updateIntervalMinutes = normalizeSubscriptionUpdateInterval(updateIntervalMinutes);
      await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    }
    return SubscriptionStore.load(context);
    });
  }

  static addManualNode(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType,
    makeActive: boolean = true
  ): Promise<SubscriptionProfile> {
    return SubscriptionStore.enqueueMutation(async (): Promise<SubscriptionProfile> => {
      const profile = await SubscriptionStore.load(context);
      return SubscriptionStore.addManualNodeToProfile(
        context, profile, name, outboundJson, configType, makeActive);
    });
  }

  static addManualNodeIfUnique(
    context: common.Context,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType,
    makeActive: boolean = false
  ): Promise<ManualNodeAddResult> {
    return SubscriptionStore.enqueueMutation(async (): Promise<ManualNodeAddResult> => {
      const profile = await SubscriptionStore.load(context);
      const duplicate = SubscriptionStore.findDuplicateNodeInProfile(profile, outboundJson, configType);
      if (duplicate !== null) {
        return { added: false, duplicate, profile };
      }
      return {
        added: true,
        duplicate: null,
        profile: await SubscriptionStore.addManualNodeToProfile(
          context, profile, name, outboundJson, configType, makeActive)
      };
    });
  }

  private static async addManualNodeToProfile(
    context: common.Context,
    profile: SubscriptionProfile,
    name: string,
    outboundJson: string,
    configType?: XrayConfigType,
    makeActive: boolean = true
  ): Promise<SubscriptionProfile> {
    let localGroup = SubscriptionStore.findGroup(profile.groups, 'sub-local');
    if (localGroup === null) {
      localGroup = {
        id: 'sub-local',
        name: '手动导入',
        url: '',
        enabled: true,
        selectedNodeId: '',
        nodes: [],
        updatedAt: Date.now(),
        userAgent: '',
        filter: '',
        prevProfile: '',
        nextProfile: '',
        allowInsecureUrl: false,
        autoUpdate: false,
        updateIntervalMinutes: DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
      };
      profile.groups.push(localGroup);
    }
    
    const validation = normalizeConfigInput(outboundJson, configType);
    const resolvedConfigType = SubscriptionStore.resolveConfigType(validation.configType, configType);
    const protocol = validation.valid ? SubscriptionStore.protocolForConfigType(resolvedConfigType, validation.protocol) : 'unknown';
    
    const nodeId = `manual-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const finalName = name.trim().length > 0 ? name.trim() : `手动-${protocol.toUpperCase()}`;
    
    const newNode: ProxyNode = {
      id: nodeId,
      name: finalName,
      protocol: protocol,
      outboundJson: validation.valid ? validation.normalizedJson : outboundJson,
      configType: resolvedConfigType,
      sourceUrl: '',
      rawLink: '',
      updatedAt: Date.now(),
      delayMs: -1,
      delayTestAt: 0,
      delayStatus: ''
    };
    
    localGroup.nodes.push(newNode);
    localGroup.updatedAt = Date.now();

    // 扫码/深链/系统分享等外部入口只保存节点，不得悄悄切换正在运行的连接。
    // 首次导入尚无任何全局选择时仍建立一个可用默认值；显式手动添加保持原行为。
    if (makeActive || profile.selectedNodeId.length === 0) {
      localGroup.selectedNodeId = nodeId;
      profile.selectedGroupId = 'sub-local';
      profile.selectedNodeId = nodeId;
    } else if (localGroup.selectedNodeId.length === 0) {
      localGroup.selectedNodeId = nodeId;
    }
    
    await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
    return SubscriptionStore.load(context);
  }

  static async findDuplicateNode(context: common.Context, outboundJson: string, configType?: XrayConfigType): Promise<ProxyNode | null> {
    const profile = await SubscriptionStore.load(context);
    return SubscriptionStore.findDuplicateNodeInProfile(profile, outboundJson, configType);
  }

  private static findDuplicateNodeInProfile(
    profile: SubscriptionProfile,
    outboundJson: string,
    configType?: XrayConfigType
  ): ProxyNode | null {
    const targetKey = proxyConfigDedupeKey(outboundJson, configType);
    if (targetKey.length === 0) {
      return null;
    }
    for (let groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      const nodes = profile.groups[groupIndex].nodes;
      for (let nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
        if (proxyNodeDedupeKey(nodes[nodeIndex]) === targetKey) {
          return nodes[nodeIndex];
        }
      }
    }
    return null;
  }

  static updateManualNode(context: common.Context, nodeId: string, name: string, outboundJson: string, configType?: XrayConfigType): Promise<ManualNodeUpdateResult> {
    return SubscriptionStore.enqueueMutation(async (): Promise<ManualNodeUpdateResult> => {
    const profile = await SubscriptionStore.load(context);
    const validation = normalizeConfigInput(outboundJson, configType);
    const resolvedConfigType = SubscriptionStore.resolveConfigType(validation.configType, configType);
    const protocol = validation.valid ? SubscriptionStore.protocolForConfigType(resolvedConfigType, validation.protocol) : 'unknown';
    const normalizedJson = validation.valid ? validation.normalizedJson : outboundJson;
    const now = Date.now();
    let selected = false;

    for (let groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      const group = profile.groups[groupIndex];
      for (let nodeIndex = 0; nodeIndex < group.nodes.length; nodeIndex++) {
        const node = group.nodes[nodeIndex];
        if (node.id !== nodeId) {
          continue;
        }
        if (node.sourceUrl.trim().length > 0 || node.rawLink.trim().length > 0) {
          return {
            updated: false,
            selected: false,
            node: null,
            profile
          };
        }
        const finalName = name.trim().length > 0 ? name.trim() : (node.name.length > 0 ? node.name : `手动-${protocol.toUpperCase()}`);
        const nextNode: ProxyNode = {
          id: node.id,
          name: finalName,
          protocol,
          outboundJson: normalizedJson,
          configType: resolvedConfigType,
          sourceUrl: '',
          rawLink: '',
          updatedAt: now,
          delayMs: -1,
          delayTestAt: 0,
          delayStatus: ''
        };
        group.nodes[nodeIndex] = nextNode;
        group.updatedAt = now;
        selected = profile.selectedNodeId === nodeId || group.selectedNodeId === nodeId;
        await SubscriptionStore.save(context, SubscriptionStore.normalize(profile));
        return {
          updated: true,
          selected,
          node: nextNode,
          profile: await SubscriptionStore.load(context)
        };
      }
    }

    return {
      updated: false,
      selected: false,
      node: null,
      profile
    };
    });
  }

  private static enqueueMutation<T>(operation: () => Promise<T>): Promise<T> {
    const task = SubscriptionStore.mutationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    SubscriptionStore.mutationTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static enqueueStorage<T>(operation: () => Promise<T>): Promise<T> {
    const task = SubscriptionStore.storageTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation()
    );
    SubscriptionStore.storageTail = task.then(
      (): void => {},
      (_error: Object): void => {}
    );
    return task;
  }

  private static save(context: common.Context, profile: SubscriptionProfile, preservePrevious: boolean = true): Promise<void> {
    return SubscriptionStore.enqueueStorage(async (): Promise<void> => {
      // 节点/订阅写入失败必须交给上层决定提示或重试；否则扫码导入、选择或删除会在
      // 内存中看似成功，应用重启后却恢复旧数据。
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const nextRaw = JSON.stringify(profile);
      if (preservePrevious) {
        const currentRaw = (await store.get(SUBSCRIPTION_KEY, '')).toString();
        if (SubscriptionStore.parseStoredProfile(currentRaw) !== null) {
          await store.put(SUBSCRIPTION_BACKUP_KEY, currentRaw);
        } else {
          const backupRaw = (await store.get(SUBSCRIPTION_BACKUP_KEY, '')).toString();
          if (SubscriptionStore.parseStoredProfile(backupRaw) === null) {
            // 首次保存也建立一份可恢复副本；已有有效备份则绝不拿损坏主副本覆盖它。
            await store.put(SUBSCRIPTION_BACKUP_KEY, nextRaw);
          }
        }
      }
      await store.put(SUBSCRIPTION_KEY, nextRaw);
      await store.flush();
    });
  }

  private static parseStoredProfile(raw: string): SubscriptionProfile | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as SubscriptionProfile;
      if (parsed === null || typeof parsed !== 'object') {
        return null;
      }
      const record = parsed as Record<string, Object>;
      // 当前格式必须有 groups；旧版迁移格式至少有 nodes。单纯的 `{}` 或错误类型
      // 不能被 normalize 成“合法空库”，否则会掩盖损坏并在下一次写入时覆盖备份。
      if (!Array.isArray(record['groups']) && !Array.isArray(record['nodes'])) {
        return null;
      }
      return SubscriptionStore.normalize(parsed);
    } catch (_error) {
      return null;
    }
  }

  private static normalize(raw: SubscriptionProfile): SubscriptionProfile {
    const rawGroups = Array.isArray(raw.groups) ? raw.groups : [];
    const rawNodes = Array.isArray(raw.nodes) ? raw.nodes : [];
    const profile: SubscriptionProfile = {
      url: SubscriptionStore.stringValue(raw.url),
      selectedNodeId: SubscriptionStore.stringValue(raw.selectedNodeId),
      nodes: rawNodes,
      updatedAt: SubscriptionStore.numberValue(raw.updatedAt, 0),
      selectedGroupId: SubscriptionStore.stringValue(raw.selectedGroupId),
      groups: rawGroups
    };

    const normalizedGroups = SubscriptionStore.normalizeGroups(profile.groups);

    if (normalizedGroups.length === 0 && (profile.url.length > 0 || profile.nodes.length > 0)) {
      normalizedGroups.push({
        id: SubscriptionStore.makeGroupId(profile.url.length > 0 ? profile.url : 'legacy'),
        name: SubscriptionStore.nameFromUrl(profile.url),
        url: profile.url,
        enabled: true,
        selectedNodeId: profile.selectedNodeId,
        nodes: SubscriptionStore.normalizeNodes(profile.nodes),
        updatedAt: profile.updatedAt,
        userAgent: '',
        filter: '',
        prevProfile: '',
        nextProfile: '',
        allowInsecureUrl: false,
        autoUpdate: false,
        updateIntervalMinutes: DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
      });
    }

    profile.groups = normalizedGroups;
    if (SubscriptionStore.findGroup(profile.groups, profile.selectedGroupId) === null) {
      profile.selectedGroupId = profile.groups.length > 0 ? profile.groups[0].id : '';
    }

    const active = SubscriptionStore.activeGroup(profile);
    if (active !== null) {
      // url / nodes / updatedAt 反映当前浏览的活动组（驱动首页节点列表）。
      profile.url = active.url;
      profile.nodes = active.nodes;
      profile.updatedAt = active.updatedAt;
    } else {
      profile.url = '';
      profile.nodes = [];
      profile.updatedAt = 0;
    }
    // selectedNodeId 是「全局当前节点」，与浏览的活动组解耦：切组不改它，仅在它已不存在于任何组时回退。
    profile.selectedNodeId = resolveGlobalSelectedNodeId(profile.groups, profile.selectedNodeId, active !== null ? active.selectedNodeId : '');
    return profile;
  }

  private static normalizeGroup(group: SubscriptionGroup, index: number): SubscriptionGroup {
    const url = SubscriptionStore.stringValue(group.url);
    const nodes = SubscriptionStore.normalizeNodes(Array.isArray(group.nodes) ? group.nodes : []);
    const fallbackId = SubscriptionStore.makeGroupId(`${url.length > 0 ? url : 'group'}-${index}`);
    const rawId = SubscriptionStore.stringValue(group.id).trim();
    const rawName = SubscriptionStore.stringValue(group.name).trim();
    return {
      id: rawId.length > 0 ? rawId : fallbackId,
      name: limitSubscriptionText(
        rawName.length > 0 ? rawName : SubscriptionStore.nameFromUrl(url),
        MAX_SUBSCRIPTION_GROUP_NAME_CHARS
      ),
      url,
      enabled: SubscriptionStore.boolValue(group.enabled, true),
      selectedNodeId: SubscriptionStore.resolveSelectedNodeId(nodes, SubscriptionStore.stringValue(group.selectedNodeId)),
      nodes,
      updatedAt: SubscriptionStore.numberValue(group.updatedAt, 0),
      userAgent: limitSubscriptionText(SubscriptionStore.stringValue(group.userAgent),
        MAX_SUBSCRIPTION_USER_AGENT_CHARS),
      filter: limitSubscriptionText(SubscriptionStore.stringValue(group.filter),
        MAX_SUBSCRIPTION_FILTER_CHARS),
      prevProfile: limitSubscriptionText(SubscriptionStore.stringValue(group.prevProfile),
        MAX_SUBSCRIPTION_PROFILE_NOTE_CHARS),
      nextProfile: limitSubscriptionText(SubscriptionStore.stringValue(group.nextProfile),
        MAX_SUBSCRIPTION_PROFILE_NOTE_CHARS),
      allowInsecureUrl: SubscriptionStore.boolValue(group.allowInsecureUrl, false),
      autoUpdate: SubscriptionStore.boolValue(group.autoUpdate, false),
      updateIntervalMinutes: normalizeSubscriptionUpdateInterval(SubscriptionStore.numberValue(
        group.updateIntervalMinutes,
        DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
      ))
    };
  }

  private static normalizeGroups(groups: Array<SubscriptionGroup>): Array<SubscriptionGroup> {
    const normalized = new Array<SubscriptionGroup>();
    const idCounts = new Map<string, number>();
    for (let index = 0; index < groups.length && normalized.length < MAX_SUBSCRIPTION_GROUP_COUNT; index++) {
      const candidate = groups[index] as Object;
      if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
        continue;
      }
      const group = SubscriptionStore.normalizeGroup(candidate as SubscriptionGroup, index);
      group.id = SubscriptionStore.uniqueId(group.id, `group-${index}`, idCounts);
      normalized.push(group);
    }
    return normalized;
  }

  private static normalizeNodes(nodes: Array<ProxyNode>): Array<ProxyNode> {
    const normalized = new Array<ProxyNode>();
    const idCounts = new Map<string, number>();
    for (let index = 0; index < nodes.length && normalized.length < MAX_SUBSCRIPTION_NODE_COUNT; index++) {
      const candidate = nodes[index] as Object;
      if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
        continue;
      }
      const node = candidate as ProxyNode;
      if (node.outboundJson !== undefined && typeof node.outboundJson !== 'string') {
        continue;
      }
      const id = SubscriptionStore.uniqueNodeId(SubscriptionStore.stringValue(node.id), index, idCounts);
      const outboundJson = SubscriptionStore.stringValue(node.outboundJson);
      const rawLink = SubscriptionStore.stringValue(node.rawLink);
      if (outboundJson.length > MAX_STORED_NODE_CONFIG_CHARS ||
        rawLink.length > MAX_STORED_NODE_CONFIG_CHARS) {
        continue;
      }
      const configType = SubscriptionStore.normalizeNodeConfigType(node.configType, outboundJson);
      const protocol = SubscriptionStore.stringValue(node.protocol);
      normalized.push({
        id,
        name: limitSubscriptionText(SubscriptionStore.stringValue(node.name), MAX_SUBSCRIPTION_NAME_CHARS),
        protocol: protocol.length > 0 ? protocol : SubscriptionStore.protocolForConfigType(configType, ''),
        outboundJson,
        configType,
        sourceUrl: SubscriptionStore.stringValue(node.sourceUrl),
        rawLink,
        updatedAt: SubscriptionStore.numberValue(node.updatedAt, 0),
        delayMs: SubscriptionStore.numberValue(node.delayMs, -1),
        delayTestAt: SubscriptionStore.numberValue(node.delayTestAt, 0),
        delayStatus: SubscriptionStore.stringValue(node.delayStatus)
      });
    }
    return normalized;
  }

  private static uniqueNodeId(rawId: string, index: number, idCounts: Map<string, number>): string {
    return SubscriptionStore.uniqueId(rawId, `node-${index}`, idCounts);
  }

  private static uniqueId(rawId: string, fallback: string, idCounts: Map<string, number>): string {
    const baseId = rawId.length > 0 ? rawId : fallback;
    const count = idCounts.get(baseId) ?? 0;
    idCounts.set(baseId, count + 1);
    if (count === 0) {
      return baseId;
    }
    return `${baseId}-${count + 1}`;
  }

  private static stringValue(value: Object | undefined | null, fallback: string = ''): string {
    return typeof value === 'string' ? value as string : fallback;
  }

  private static boolValue(value: Object | undefined | null, fallback: boolean): boolean {
    return typeof value === 'boolean' ? value as boolean : fallback;
  }

  private static numberValue(value: Object | undefined | null, fallback: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value as number)) {
      return fallback;
    }
    return Math.floor(value as number);
  }

  private static mergeNodeRuntime(existing: Array<ProxyNode>, next: Array<ProxyNode>): Array<ProxyNode> {
    const merged = new Array<ProxyNode>();
    for (let index = 0; index < next.length; index++) {
      const node = next[index];
      const previous = SubscriptionStore.findNode(existing, node.id);
      if (previous !== null) {
        node.delayMs = previous.delayMs;
        node.delayStatus = previous.delayStatus;
        node.delayTestAt = previous.delayTestAt;
      }
      merged.push(node);
    }
    return merged;
  }

  public static activeGroup(profile: SubscriptionProfile): SubscriptionGroup | null {
    return SubscriptionStore.findGroup(profile.groups, profile.selectedGroupId);
  }

  private static findGroup(groups: Array<SubscriptionGroup>, groupId: string): SubscriptionGroup | null {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].id === groupId) {
        return groups[index];
      }
    }
    return null;
  }

  public static findGroupByUrl(groups: Array<SubscriptionGroup>, url: string): SubscriptionGroup | null {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].url === url) {
        return groups[index];
      }
    }
    return null;
  }

  private static findNode(nodes: Array<ProxyNode>, nodeId: string): ProxyNode | null {
    for (let index = 0; index < nodes.length; index++) {
      if (nodes[index].id === nodeId) {
        return nodes[index];
      }
    }
    return null;
  }

  private static resolveSelectedNodeId(nodes: Array<ProxyNode>, selectedNodeId: string): string {
    if (SubscriptionStore.findNode(nodes, selectedNodeId) !== null) {
      return selectedNodeId;
    }
    return nodes.length > 0 ? nodes[0].id : '';
  }

  private static dedupeNodes(nodes: Array<ProxyNode>): Array<ProxyNode> {
    return dedupeProxyNodes(nodes);
  }

  private static createGroup(
    url: string,
    name: string,
    userAgent: string = '',
    filter: string = '',
    prevProfile: string = '',
    nextProfile: string = '',
    allowInsecureUrl: boolean = false,
    autoUpdate: boolean = false,
    updateIntervalMinutes: number = DEFAULT_SUBSCRIPTION_UPDATE_INTERVAL_MINUTES
  ): SubscriptionGroup {
    const seed = `${url}-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    return {
      id: SubscriptionStore.makeGroupId(seed),
      name,
      url,
      enabled: true,
      selectedNodeId: '',
      nodes: [],
      updatedAt: 0,
      userAgent,
      filter,
      prevProfile,
      nextProfile,
      allowInsecureUrl,
      autoUpdate,
      updateIntervalMinutes: normalizeSubscriptionUpdateInterval(updateIntervalMinutes)
    };
  }

  private static createEmpty(): SubscriptionProfile {
    return {
      url: '',
      selectedNodeId: '',
      nodes: [],
      updatedAt: 0,
      selectedGroupId: '',
      groups: []
    };
  }

  private static nameFromUrl(url: string): string {
    // Subscription URLs can embed Basic Auth or token-like userinfo. Derived group names
    // are rendered and logged, so reuse the credential-stripping authority parser.
    return subscriptionNameFromDeepLink(url);
  }

  private static makeGroupId(value: string): string {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) {
      hash = (hash ^ value.charCodeAt(index)) * 16777619;
      hash = hash >>> 0;
    }
    return `sub-${hash.toString(16)}`;
  }

  private static normalizeNodeConfigType(configType: Object | undefined | null, outboundJson: string): XrayConfigType {
    if (configType === 'full') {
      return 'full';
    }
    if (configType === 'proxy-chain') {
      return 'proxy-chain';
    }
    if (configType === 'policy-group') {
      return 'policy-group';
    }
    const validation = normalizeConfigInput(outboundJson);
    return validation.configType === 'full' || validation.configType === 'proxy-chain' || validation.configType === 'policy-group' ? validation.configType : 'outbound';
  }

  private static resolveConfigType(detected?: XrayConfigType, fallback?: XrayConfigType): XrayConfigType {
    if (detected === 'full') {
      return 'full';
    }
    if (detected === 'proxy-chain') {
      return 'proxy-chain';
    }
    if (detected === 'policy-group') {
      return 'policy-group';
    }
    if (detected === 'outbound') {
      return 'outbound';
    }
    if (fallback === 'full' || fallback === 'proxy-chain' || fallback === 'policy-group') {
      return fallback;
    }
    return 'outbound';
  }

  private static protocolForConfigType(configType: XrayConfigType, detectedProtocol: string): string {
    if (configType === 'full') {
      return 'custom';
    }
    if (configType === 'proxy-chain') {
      return 'proxy-chain';
    }
    if (configType === 'policy-group') {
      return 'policy-group';
    }
    return detectedProtocol;
  }
}
