// Centralized USDC formatting so every page renders amounts the same friendly way.
// USDC is a stablecoin: showing 6 decimals is noise. Default to 2 decimals + thousand separators.

export function fmtUsdc(
  value: string | number | bigint | null | undefined,
  decimals = 2,
): string {
  if (value === null || value === undefined || value === '') return '0';
  const n = typeof value === 'bigint' ? Number(value) : Number(value);
  if (!Number.isFinite(n)) return '0';
  return n.toLocaleString('bg-BG', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// For dust-sensitive contexts (e.g., LP tranche live value when very small).
export function fmtUsdcSmart(value: string | number | bigint | null | undefined): string {
  if (value === null || value === undefined || value === '') return '0';
  const n = typeof value === 'bigint' ? Number(value) : Number(value);
  if (!Number.isFinite(n)) return '0';
  if (n === 0) return '0';
  if (Math.abs(n) >= 1) return fmtUsdc(n, 2);
  if (Math.abs(n) >= 0.01) return fmtUsdc(n, 4);
  return '< 0.01';
}
