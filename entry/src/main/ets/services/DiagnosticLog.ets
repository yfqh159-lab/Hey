import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { redactDiagnosticText } from '../core/DiagnosticRedaction';

const LOG_FILE_NAME: string = 'hey-vpn-diagnostics.jsonl';
const MAX_FILE_BYTES: number = 256 * 1024;
const TRIMMED_FILE_BYTES: number = 160 * 1024;
const DIAGNOSTIC_READ_TIMEOUT_MS: number = 2000;

function withDiagnosticReadTimeout(promise: Promise<string>): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error('diagnostic read timed out')),
      DIAGNOSTIC_READ_TIMEOUT_MS);
    promise.then((value: string) => {
      clearTimeout(timerId);
      resolve(value);
    }, (error: Object) => {
      clearTimeout(timerId);
      reject(error);
    });
  });
}

export interface DiagnosticEvent {
  at: number;
  level: string;
  source: string;
  message: string;
  sessionId?: string;
  details?: string;
  uploadBytes?: number;
  downloadBytes?: number;
  xrayRunning?: boolean;
  tunRunning?: boolean;
}

export class DiagnosticLog {
  private static readInFlight: Promise<string> | null = null;

  static append(context: common.Context, event: DiagnosticEvent): void {
    const path = DiagnosticLog.path(context);
    let file: fs.File | null = null;
    try {
      DiagnosticLog.rotateIfNeeded(path);
      file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `${JSON.stringify(DiagnosticLog.redact(event))}\n`);
    } catch (error) {
      console.error(`Diagnostic append failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    } finally {
      DiagnosticLog.closeFile(file, 'append');
    }
  }

  static async read(context: common.Context, limit: number = 80): Promise<Array<DiagnosticEvent>> {
    const path = DiagnosticLog.path(context);
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      if (DiagnosticLog.readInFlight !== null) {
        return [];
      }
      const readPromise = fs.readText(path);
      DiagnosticLog.readInFlight = readPromise;
      readPromise.then(
        (_value: string): void => DiagnosticLog.releaseRead(readPromise),
        (_error: Object): void => DiagnosticLog.releaseRead(readPromise)
      );
      // 文件系统 Promise 在异常存储状态下也不能永久占住首页共享刷新队列或 VPN
      // 启停确认。迟到读取没有副作用；超时本轮按空日志处理，但原读取结算前不再
      // 叠加新的底层任务，避免异常存储状态下累积无限 pending Promise。
      const raw = await withDiagnosticReadTimeout(readPromise);
      return DiagnosticLog.parse(raw, limit);
    } catch (error) {
      console.error(`Diagnostic read failed: ${redactDiagnosticText(JSON.stringify(error))}`);
      return [];
    }
  }

  private static releaseRead(readPromise: Promise<string>): void {
    if (DiagnosticLog.readInFlight === readPromise) {
      DiagnosticLog.readInFlight = null;
    }
  }

  static clear(context: common.Context): void {
    const path = DiagnosticLog.path(context);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    } catch (error) {
      console.error(`Diagnostic clear failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    } finally {
      DiagnosticLog.closeFile(file, 'clear');
    }
  }

  static format(event: DiagnosticEvent, timeFormatter: (value: number) => string): string {
    const parts: Array<string> = [`${timeFormatter(event.at)}  [${event.source}] ${event.message}`];
    if (event.details !== undefined && event.details.length > 0) {
      parts.push(event.details);
    }
    if (event.uploadBytes !== undefined || event.downloadBytes !== undefined) {
      parts.push(`up=${event.uploadBytes ?? 0} down=${event.downloadBytes ?? 0}`);
    }
    return parts.join('  ');
  }

  private static path(context: common.Context): string {
    return `${context.filesDir}/${LOG_FILE_NAME}`;
  }

  private static redact(event: DiagnosticEvent): DiagnosticEvent {
    const sanitized: DiagnosticEvent = {
      at: event.at,
      level: event.level,
      source: event.source,
      message: redactDiagnosticText(event.message)
    };
    if (event.details !== undefined) {
      sanitized.details = redactDiagnosticText(event.details);
    }
    if (event.sessionId !== undefined) {
      sanitized.sessionId = redactDiagnosticText(event.sessionId);
    }
    sanitized.uploadBytes = event.uploadBytes;
    sanitized.downloadBytes = event.downloadBytes;
    sanitized.xrayRunning = event.xrayRunning;
    sanitized.tunRunning = event.tunRunning;
    return sanitized;
  }

  private static rotateIfNeeded(path: string): void {
    let file: fs.File | null = null;
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const stat = fs.statSync(path);
      if (stat.size <= MAX_FILE_BYTES) {
        return;
      }

      const raw = fs.readTextSync(path);
      const trimmed = raw.length > TRIMMED_FILE_BYTES ? raw.slice(raw.length - TRIMMED_FILE_BYTES) : raw;
      file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, trimmed);
    } catch (error) {
      console.error(`Diagnostic rotate failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    } finally {
      DiagnosticLog.closeFile(file, 'rotate');
    }
  }

  private static parse(raw: string, limit: number): Array<DiagnosticEvent> {
    const lines = raw.split('\n').filter((line: string) => line.trim().length > 0);
    const events: Array<DiagnosticEvent> = [];
    for (let index = lines.length - 1; index >= 0 && events.length < limit; index--) {
      try {
        events.push(DiagnosticLog.redact(JSON.parse(lines[index]) as DiagnosticEvent));
      } catch (error) {
        events.push({
          at: Date.now(),
          level: 'warn',
          source: 'diagnostic',
          message: 'Skipped malformed diagnostic line.',
          details: redactDiagnosticText(JSON.stringify(error))
        });
      }
    }
    return events;
  }

  private static closeFile(file: fs.File | null, operation: string): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (error) {
      console.error(`Diagnostic ${operation} close failed: ${redactDiagnosticText(JSON.stringify(error))}`);
    }
  }
}
