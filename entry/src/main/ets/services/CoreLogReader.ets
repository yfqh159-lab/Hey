import { fileIo as fs } from '@kit.CoreFileKit';
import { LogEntry, normalizeLogLevel } from '../features/logs/LogModel';
import { XRAY_CORE_LOG_FILE } from '../core/XrayConfig';
import { SINGBOX_CORE_LOG_FILE } from '../core/SingboxConfig';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';

const MAX_READ_BYTES: number = 128 * 1024;
const DEFAULT_LIMIT: number = 200;

// Xray 核心日志行格式：`2024/01/15 10:30:45 [Warning] app/dns: message`（时间可带小数秒）。
const LINE_RE: RegExp = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.\d+)? \[([A-Za-z]+)\] (.*)$/;

/**
 * 核心运行日志读取器。
 *
 * 核心（Xray）把分级日志写到 filesDir/xray-core.log（见 injectXrayLogFile）。
 * 这里读取尾部并解析成 LogEntry，让 Logcat 页的分级过滤真正有数据。
 * 全程纯文件读取，不触碰 native .so。
 */

// 纯解析：把核心日志文本切成结构化条目。无法解析时间/等级的续行（多行堆栈）并入上一条。
export function parseCoreLog(raw: string, limit: number = DEFAULT_LIMIT): Array<LogEntry> {
  const lines = raw.split('\n');
  const entries = new Array<LogEntry>();
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (line.trim().length === 0) {
      continue;
    }
    const match = line.match(LINE_RE);
    if (match === null) {
      // 续行：附加到最近一条核心日志，保持多行错误完整
      if (entries.length > 0) {
        const last = entries[entries.length - 1];
        const sanitizedContinuation = redactDiagnosticText(line);
        last.message = `${last.message}\n${sanitizedContinuation}`;
        last.raw = `${last.raw}\n${sanitizedContinuation}`;
      }
      continue;
    }
    const year = parseInt(match[1], 10);
    const month = parseInt(match[2], 10);
    const day = parseInt(match[3], 10);
    const hour = parseInt(match[4], 10);
    const minute = parseInt(match[5], 10);
    const second = parseInt(match[6], 10);
    const at = new Date(year, month - 1, day, hour, minute, second).getTime();
    const time = `${match[4]}:${match[5]}:${match[6]}`;
    const sanitizedMessage = redactDiagnosticText(match[8]);
    entries.push({
      at: at,
      time: time,
      level: normalizeLogLevel(match[7]),
      source: 'core',
      message: sanitizedMessage,
      raw: `${line.substring(0, line.length - match[8].length)}${sanitizedMessage}`
    });
  }
  if (entries.length > limit) {
    return entries.slice(entries.length - limit);
  }
  return entries;
}

// 读取核心日志文件尾部并解析。文件被核心持续 append，只取尾部 MAX_READ_BYTES 防爆。
export function readCoreLogEntries(filesDir: string, limit: number = DEFAULT_LIMIT): Array<LogEntry> {
  const path = `${filesDir}/${XRAY_CORE_LOG_FILE}`;
  try {
    if (!fs.accessSync(path)) {
      return [];
    }
    const stat = fs.statSync(path);
    if (stat.size <= 0) {
      return [];
    }
    const start = stat.size > MAX_READ_BYTES ? stat.size - MAX_READ_BYTES : 0;
    const length = stat.size - start;
    const raw = fs.readTextSync(path, { offset: start, length: length });
    // 从中间截断读取时，丢弃首个可能不完整的行
    const text = start > 0 ? raw.slice(raw.indexOf('\n') + 1) : raw;
    return parseCoreLog(text, limit);
  } catch (error) {
    return [];
  }
}

// 清空核心日志文件（用户主动清空时）。运行中核心以 O_APPEND 持有 fd，截断不会崩溃。
// 先 unlink 再由 ArkTS 主进程重建：核心（Go）自建的文件是 0600（umask 0077），hdc/外部读不了；
// 主进程 fs.openSync 建的是 0660（组可读），核心随后以 O_APPEND 打开保留该权限，
// 便于 `hdc file recv` 拉取核心分级日志做诊断。
export function clearCoreLog(filesDir: string): void {
  prepareGroupReadableLog(`${filesDir}/${XRAY_CORE_LOG_FILE}`);
}

// sing-box 同理：主进程先建 0660 的 singbox-core.log，核心随后 O_APPEND 打开保留组可读权限。
export function clearSingboxLog(filesDir: string): void {
  prepareGroupReadableLog(`${filesDir}/${SINGBOX_CORE_LOG_FILE}`);
}

function prepareGroupReadableLog(path: string): void {
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (error) {
    // 文件可能不存在或被占用，忽略
  }
  try {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.closeSync(file);
  } catch (error) {
    // 创建失败忽略，核心仍会自建（回落到 0600）
  }
}
