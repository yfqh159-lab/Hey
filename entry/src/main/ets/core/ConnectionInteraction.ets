import { DeepLinkControlAction } from './DeepLink';
import { ConnectionStatus } from './Profile';

/**
 * STARTING is deliberately cancellable: the connection controller uses start generations
 * to invalidate every continuation after stop. STOPPING and network-recovery busy states
 * remain non-interactive so a second operation cannot overlap cleanup.
 */
export function canCancelStartingConnection(status: ConnectionStatus): boolean {
  return status === ConnectionStatus.STARTING;
}

export function shouldOfferConnectionStop(
  status: ConnectionStatus,
  cleanupRequired: boolean
): boolean {
  return cleanupRequired || status === ConnectionStatus.STARTING || status === ConnectionStatus.RUNNING;
}

export function shouldDeferBusyControlAction(
  action: DeepLinkControlAction,
  status: ConnectionStatus,
  busy: boolean
): boolean {
  if (!busy) {
    return false;
  }
  return !(canCancelStartingConnection(status) && (action === 'stop' || action === 'toggle'));
}
