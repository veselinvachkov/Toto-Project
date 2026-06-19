/// Decodes ethers v6 transaction errors into friendly messages for known
/// custom errors (lottery, USDC, OpenZeppelin, Chainlink VRF) instead of
/// raw 4-byte selectors.

/// 4-byte selector → user-facing message. Selectors are lowercase
/// keccak256(signature)[:4].
const SELECTOR_MESSAGES: Record<string, string> = {
  // ── BulgarianToto custom errors ─────────────────────────────────────────
  '0x57e25a09': 'Invalid game ID. Choose 5/35 or 6/49.',
  '0x5a0f916e': 'Invalid number of picks for this game.',
  '0x74cbd35f': 'One of the numbers is out of the allowed range.',
  '0xc1cb9f73': 'Duplicate number in your selection.',
  '0x3d9ab53d': 'The round is not in the correct state for this action.',
  '0xdb58cd9a': 'Ticket purchases for this round have closed.',
  '0x65ea4ffd': 'The refund window for this ticket has expired.',
  '0x085de625': 'Too early: the draw time has not arrived yet.',
  '0x30cd7471': 'You are not the owner of this ticket.',
  '0x560ff900': 'This ticket has already been claimed or refunded.',
  '0x969bf728': 'There is nothing to claim from this ticket.',
  '0xc3fa7054': 'Wrong round ID. Use the current round.',
  '0xcbca5aa2': 'The amount must be greater than zero.',
  '0xc867df3a': 'The prize pool would have a negative balance.',
  '0x406cb379': 'The first draw time is too soon. It must be in the future.',
  '0x4e0141b1': 'The LP deposit amount must be greater than zero.',
  '0xb0678679': 'The pool is below the minimum threshold for LPs.',
  '0xf5072f1d': 'You have no LP shares to withdraw.',
  '0x6fa5be9e': 'The LP tranche is still locked.',
  '0xc8fea096': 'Invalid LP tranche.',
  '0x39996567': 'Insufficient LP shares.',
  '0x8313ea3c': 'The previous round has not been finalized yet.',
  '0xbb55fd27': 'Insufficient liquidity in the pool.',

  // ── ERC20 (OpenZeppelin v5) ─────────────────────────────────────────────
  '0xfb8f41b2': 'USDC approval is required. Approve the contract to spend your USDC and try again.',
  '0xe450d38c': 'Insufficient USDC balance.',
  '0x96c6fd1e': 'Invalid sender address.',
  '0xec442f05': 'Invalid receiver address.',
  '0xe602df05': 'Invalid approver address.',
  '0x94280d62': 'Invalid spender address.',

  // ── Ownable / AccessControl (OpenZeppelin v5) ───────────────────────────
  '0x118cdaa7': 'Only the contract owner can call this function.',
  '0xe2517d3f': 'Your account is missing the required role.',

  // ── ReentrancyGuard / Pausable ──────────────────────────────────────────
  '0x3ee5aeb5': 'A reentrant call was detected.',
  '0xd93c0665': 'The contract is paused.',
  '0x8dfc202b': 'The contract is not paused.',

  // ── SafeERC20 / Address ─────────────────────────────────────────────────
  '0x5274afe7': 'The USDC transfer failed (the token rejected the operation).',
  '0x9996b315': 'The target address contains no contract code.',
  '0x1425ea42': 'The internal call failed.',

  // ── Chainlink VRF V2.5 / V2Plus ─────────────────────────────────────────
  '0x79bfd401': 'This contract is not registered as a consumer of the VRF subscription. Add it at vrf.chain.link.',
  '0x1f6a65b6': 'The VRF subscription does not exist.',
  '0xcf479181': 'The VRF subscription has insufficient LINK balance.',
  '0xd8a3fb52': 'The caller is not the owner of the VRF subscription.',
  '0xf0019fe6': 'The consumer is not authorized for this VRF subscription.',
};

function decodeSelector(data: string): string | null {
  if (typeof data !== 'string' || !data.startsWith('0x') || data.length < 10) return null;
  const selector = data.slice(0, 10).toLowerCase();
  return SELECTOR_MESSAGES[selector] ?? null;
}

/// Walk a tangled ethers/wallet error object to find revert data anywhere in it.
function extractRevertData(e: any): string | undefined {
  const candidates: any[] = [
    e?.data,
    e?.error?.data,
    e?.error?.data?.data,
    e?.error?.data?.originalError?.data,
    e?.info?.error?.data,
    e?.cause?.data,
    e?.cause?.error?.data,
  ];
  for (const c of candidates) {
    if (typeof c === 'string' && c.startsWith('0x') && c.length >= 10) return c;
    if (c && typeof c === 'object' && typeof c.data === 'string') return c.data;
  }
  return undefined;
}

export function formatError(e: any): string {
  if (!e) return 'Unknown error';

  if (e?.code === 'ACTION_REJECTED' || e?.code === 4001) return 'The transaction was rejected in the wallet';

  // 1. ethers v6 already decoded a custom error from a known ABI.
  const revertName = e?.revert?.name;
  if (revertName) {
    const args = e?.revert?.args;
    // Map common decoded errors to friendly strings.
    const byName: Record<string, string> = {
      ERC20InsufficientAllowance: SELECTOR_MESSAGES['0xfb8f41b2'],
      ERC20InsufficientBalance: SELECTOR_MESSAGES['0xe450d38c'],
      OwnableUnauthorizedAccount: SELECTOR_MESSAGES['0x118cdaa7'],
      EnforcedPause: SELECTOR_MESSAGES['0xd93c0665'],
      ReentrancyGuardReentrantCall: SELECTOR_MESSAGES['0x3ee5aeb5'],
      InvalidConsumer: SELECTOR_MESSAGES['0x79bfd401'],
      InsufficientBalance: SELECTOR_MESSAGES['0xcf479181'],
    };
    if (byName[revertName]) return byName[revertName];
    if (args && args.length > 0) {
      return `${revertName}(${args.map((a: any) => String(a)).join(', ')})`;
    }
    return revertName;
  }

  // 2. Raw revert data → look up by selector.
  const data = extractRevertData(e);
  if (data) {
    const friendly = decodeSelector(data);
    if (friendly) return friendly;
    return `The transaction was reverted (selector ${data.slice(0, 10)}).`;
  }

  // 3. Provider-supplied string.
  return e?.shortMessage || e?.reason || e?.message || 'The transaction failed';
}
