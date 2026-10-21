import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';

const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA';

/**
 * 在用户明确点击扫码入口后申请相机权限。不要在页面加载或应用启动时调用。
 */
export async function requestCameraPermission(context: common.UIAbilityContext): Promise<boolean> {
  // 用户明确拒绝返回 false；权限管理器或系统能力自身异常则交给页面现有 catch，显示
  // “扫码失败”及脱敏原因。不能把设备/服务故障伪装成用户拒绝权限。
  const atManager = abilityAccessCtrl.createAtManager();
  const result = await atManager.requestPermissionsFromUser(context, [CAMERA_PERMISSION]);
  return result.authResults.length === 1 && result.authResults[0] === 0;
}

/**
 * 拉起系统相机扫码（含相册入口），返回扫描到的原始文本。
 * 用户取消或未扫到内容时返回空字符串。
 */
export async function scanQrCode(context: common.UIAbilityContext): Promise<string> {
  const options: scanBarcode.ScanOptions = {
    scanTypes: [scanCore.ScanType.QR_CODE],
    enableMultiMode: false,
    enableAlbum: true
  };
  const result = await scanBarcode.startScanForResult(context, options);
  const value = result?.originalValue;
  return value ? value.trim() : '';
}

/**
 * 判断扫码错误是否为用户主动取消（取消时无需提示）。
 */
export function isScanCancelled(error: Object): boolean {
  const code = (error as Record<string, Object>)['code'];
  return code === 20001 || code === '20001' || code === 1000500002 || code === '1000500002';
}
