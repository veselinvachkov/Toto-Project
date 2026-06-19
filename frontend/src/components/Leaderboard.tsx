import { useEffect, useState } from 'react';
import { useTotoRead } from '../hooks/useToto';
import { readProvider } from '../hooks/useEthers';
import { DEPLOY_BLOCK } from '../config/contract';
import { fmtUsdc } from '../utils/format';

// Public RPCs cap `eth_getLogs` block ranges (publicnode ~10k). Query the
// Claimed history in chunks starting from the deploy block instead of genesis.
const LOG_CHUNK = 9_000;

interface Entry {
  ticketId: string;
  owner: string;
  amount: number; // USDC, parsed
}

const SHORT_ADDR = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;

// Top 5 *distinct* wins. Collapse by (owner, amount) so one winner claiming
// many identical tickets occupies a single slot, while two different players
// winning the same amount stay as separate entries.
function topDistinct(all: Iterable<Entry>): Entry[] {
  const distinct = new Map<string, Entry>();
  for (const e of all) {
    const key = `${e.owner.toLowerCase()}|${e.amount}`;
    if (!distinct.has(key)) distinct.set(key, e);
  }
  return [...distinct.values()].sort((a, b) => b.amount - a.amount).slice(0, 5);
}

// Module-level cache shared across remounts and the 30s refreshes. History is
// scanned from DEPLOY_BLOCK once; later loads only query blocks since `scannedTo`.
const logCache: { byTicket: Map<string, Entry>; scannedTo: number } = {
  byTicket: new Map(),
  scannedTo: DEPLOY_BLOCK - 1,
};
let inflight: Promise<void> | null = null;

export default function Leaderboard() {
  const toto = useTotoRead();
  const [entries, setEntries] = useState<Entry[]>(() =>
    topDistinct(logCache.byTicket.values()),
  );
  const [loading, setLoading] = useState(logCache.byTicket.size === 0);

  useEffect(() => {
    let cancelled = false;

    const publish = () => {
      if (!cancelled) {
        setEntries(topDistinct(logCache.byTicket.values()));
        setLoading(false);
      }
    };

    const ingest = (logs: any[]) => {
      for (const log of logs) {
        logCache.byTicket.set(log.args[0].toString(), {
          ticketId: log.args[0].toString(),
          owner: log.args[1] as string,
          amount: Number(log.args[2]) / 1e6,
        });
      }
    };

    // Scan [from, to] as parallel chunks with bounded concurrency. Each window
    // that returns publishes immediately, so the board fills in progressively
    // instead of blocking on the entire history (the old sequential loop did
    // one round-trip per 9k blocks before showing anything). `scannedTo` only
    // advances across the leading run of successful chunks, so a failed window
    // is retried on the next refresh rather than skipped.
    const scanRange = async (from: number, to: number) => {
      const filter = toto.filters.Claimed();
      const chunks: Array<{ f: number; t: number }> = [];
      for (let f = from; f <= to; f += LOG_CHUNK + 1) {
        chunks.push({ f, t: Math.min(f + LOG_CHUNK, to) });
      }

      const CONCURRENCY = 6;
      const ok = new Array<boolean>(chunks.length).fill(false);
      let next = 0;

      const worker = async () => {
        while (!cancelled) {
          const i = next++;
          if (i >= chunks.length) return;
          try {
            const logs = await toto.queryFilter(filter, chunks[i].f, chunks[i].t);
            ingest(logs as any[]);
            ok[i] = true;
            publish(); // progressive update as each window returns
          } catch { /* leave ok[i] false → retried on next refresh */ }
        }
      };

      await Promise.all(
        Array.from({ length: Math.min(CONCURRENCY, chunks.length) }, worker),
      );

      // Advance scannedTo across the leading contiguous run of OK chunks only.
      let prefix = 0;
      while (prefix < chunks.length && ok[prefix]) prefix++;
      if (prefix > 0) logCache.scannedTo = chunks[prefix - 1].t;
    };

    const load = async () => {
      // Coalesce concurrent loads (mount + interval) into one scan.
      if (inflight) { await inflight; }
      else {
        inflight = (async () => {
          try {
            const latest = await readProvider.getBlockNumber();
            if (latest > logCache.scannedTo) {
              await scanRange(logCache.scannedTo + 1, latest);
            }
          } catch { /* keep previously loaded entries */ }
        })();
        try { await inflight; } finally { inflight = null; }
      }

      publish();
    };

    load();
    // Refresh so new wins show up without a manual reload.
    const id = setInterval(load, 30_000);
    return () => { cancelled = true; clearInterval(id); };
  }, [toto]);

  return (
    <aside className="leaderboard card">
      <h3 className="mb-1" style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          width="1.2em"
          height="1.2em"
          aria-hidden="true"
        >
          <defs>
            <linearGradient id="trophyGold" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#FFE082" />
              <stop offset="50%" stopColor="#FFC107" />
              <stop offset="100%" stopColor="#B8860B" />
            </linearGradient>
          </defs>
          <path
            fill="url(#trophyGold)"
            stroke="#7A5200"
            strokeWidth="0.5"
            d="M7 3h10v2h3a2 2 0 0 1 2 2v2a4 4 0 0 1-4 4h-.4a6 6 0 0 1-4.6 4.9V20h3a1 1 0 0 1 1 1v1H7v-1a1 1 0 0 1 1-1h3v-2.1A6 6 0 0 1 6.4 13H6a4 4 0 0 1-4-4V7a2 2 0 0 1 2-2h3V3zm0 4H4v2a2 2 0 0 0 2 2h1V7zm10 0v4h1a2 2 0 0 0 2-2V7h-3z"
          />
        </svg>
        Top 5 wins
      </h3>
      <p className="muted mb-2" style={{ fontSize: '0.8rem' }}>
        The largest payouts of all time
      </p>

      {loading && <p className="muted" style={{ fontSize: '0.85rem' }}>Loading...</p>}

      {!loading && entries.length === 0 && (
        <p className="muted" style={{ fontSize: '0.85rem' }}>No wins yet</p>
      )}

      {!loading && entries.length > 0 && (
        <ol className="leaderboard-list">
          {entries.map((e, i) => (
            <li key={`${e.ticketId}-${i}`}>
              <span className="lb-rank">#{i + 1}</span>
              <span className="lb-addr" title={e.owner}>{SHORT_ADDR(e.owner)}</span>
              <span className="lb-amount">{fmtUsdc(e.amount)} USDC</span>
            </li>
          ))}
        </ol>
      )}
    </aside>
  );
}
