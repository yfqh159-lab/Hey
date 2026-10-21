/**
 * 订阅/节点列表的视觉派生工具（纯逻辑，无 UI、无 any）。
 *
 * - 分组卡头像：由名称确定性地取「身份色」+ 取首个有意义字符作为字母标识；
 * - 节点行国旗：优先提取名称里内嵌的国旗 emoji，否则按地区关键字映射，
 *   最后回退地球图标，并给出去掉前缀国旗后的展示名；
 * - 延迟分级：把 ProxyNode 的延迟/状态归一到 5 档，用于信号点与文字着色。
 */
import { isNeutralDelayStatus, ProxyNode } from '../../core/Profile';
import { AppColor } from '../../theme/Theme';

/** 头像调色板：给每个来源一个稳定的品牌色。 */
const AVATAR_COLORS: Array<string> = ['#5B6CF0', '#16A34A', '#8B5CF6', '#0EA5E9', '#E0457B', '#D97706', '#0D9488'];

/** 由名称做一个稳定哈希，取一个头像色。 */
export function avatarColor(name: string): string {
  let hash = 0;
  for (let index = 0; index < name.length; index++) {
    hash = (hash * 31 + name.charCodeAt(index)) >>> 0;
  }
  return AVATAR_COLORS[hash % AVATAR_COLORS.length];
}

/** 取首个有意义字符（中文取首字、英文取首字母大写）作为字母标识。 */
export function monogram(name: string): string {
  for (let index = 0; index < name.length; index++) {
    const ch = name.charAt(index);
    if (/[A-Za-z一-龥]/.test(ch)) {
      return ch.toUpperCase();
    }
  }
  const first = name.trim().charAt(0);
  return first.length > 0 ? first.toUpperCase() : '#';
}

export interface NodePresentation {
  flag: string;
  label: string;
}

/** 计算节点行展示：名称首字母角标 + 名称。不按名称推断任何地区归属。 */
export function nodePresentation(name: string): NodePresentation {
  return { flag: monogram(name), label: name.trim() };
}

export type NodeDelayLevel = 'good' | 'warn' | 'bad' | 'testing' | 'pending';

/** 把节点的延迟/状态归一到 5 档（与设计稿阈值一致：≤300 绿 / ≤900 橙 / 失败红 / testing 橙）。 */
export function nodeDelayLevel(node: ProxyNode): NodeDelayLevel {
  if (node.delayStatus === 'testing') {
    return 'testing';
  }
  if (node.delayMs >= 0) {
    if (node.delayMs <= 300) {
      return 'good';
    }
    if (node.delayMs <= 900) {
      return 'warn';
    }
    return 'bad';
  }
  if (isNeutralDelayStatus(node.delayStatus)) {
    return 'pending';
  }
  if (node.delayStatus.length > 0) {
    return 'bad';
  }
  return 'pending';
}

/** 延迟档位 → 主题色（自动适配明暗）。 */
export function delayLevelColor(level: NodeDelayLevel): ResourceColor {
  if (level === 'good') {
    return AppColor.success;
  }
  if (level === 'warn') {
    return AppColor.warning;
  }
  if (level === 'bad') {
    return AppColor.danger;
  }
  if (level === 'testing') {
    return AppColor.brand;
  }
  return AppColor.textTertiary;
}
