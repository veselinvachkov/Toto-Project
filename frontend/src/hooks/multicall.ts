import { Contract } from 'ethers';
import { readProvider } from './useEthers';

// Multicall3 lives at the same canonical address on every chain (incl. Sepolia).
// Collapsing N `eth_call`s into one is the biggest win against rate-limited
// public RPCs - a page that fired ~90 reads now sends a single request.
const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11';

const MULTICALL3_ABI = [
  'function aggregate3((address target, bool allowFailure, bytes callData)[] calls) view returns ((bool success, bytes returnData)[] returnData)',
];

const multicall3 = new Contract(MULTICALL3_ADDRESS, MULTICALL3_ABI, readProvider);

export interface Call {
  /** Function name as declared in the contract ABI. */
  fn: string;
  /** Arguments for the call (default none). */
  args?: any[];
  /** If false, a single failing sub-call reverts the whole batch (default true). */
  allowFailure?: boolean;
}

// Keep each on-chain aggregate3 within a comfortable response/gas size. A few
// hundred view calls fit fine, but chunking keeps very large pages (e.g. a
// round with thousands of tickets) from producing one oversized eth_call.
const CHUNK = 200;

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/**
 * Batch multiple read calls on a single contract into Multicall3 `aggregate3`
 * request(s). Returns results positionally aligned with `calls`.
 *
 * Each result is the decoded function output:
 *   - single-output functions return the bare value (e.g. `getUserTickets` -> bigint[])
 *   - tuple-returning functions return the tuple (named + indexed access preserved)
 *   - multi-output functions return the full decoded Result array
 *   - a failed sub-call (when allowFailure) returns `undefined`
 */
export async function multicall(
  contract: Contract,
  calls: Call[],
): Promise<any[]> {
  if (calls.length === 0) return [];

  const target = contract.target as string;
  const iface = contract.interface;

  const encoded = calls.map((c) => ({
    target,
    allowFailure: c.allowFailure ?? true,
    callData: iface.encodeFunctionData(c.fn, c.args ?? []),
  }));

  // One aggregate3 per chunk; chunks run concurrently but are still only a
  // handful of requests even for large pages.
  const chunks = chunk(encoded, CHUNK);
  const callChunks = chunk(calls, CHUNK);

  const decodedChunks = await Promise.all(
    chunks.map(async (payload, ci) => {
      const results: { success: boolean; returnData: string }[] =
        await multicall3.aggregate3(payload);
      return results.map((r, i) => {
        if (!r.success || r.returnData === '0x') return undefined;
        try {
          const decoded = iface.decodeFunctionResult(callChunks[ci][i].fn, r.returnData);
          return decoded.length === 1 ? decoded[0] : decoded;
        } catch {
          return undefined;
        }
      });
    }),
  );

  return decodedChunks.flat();
}
