import type { ProposalDiffResponse } from "./types";

export interface WordDiffToken {
  kind: "equal" | "added" | "removed";
  text: string;
}

export interface WordDiffResult {
  tokens: WordDiffToken[];
  addedWords: number;
  removedWords: number;
}

function tokenizeWords(input: string): string[] {
  return input.match(/\S+|\s+/g) ?? [];
}

function countNonWs(tokens: string[]): number {
  let n = 0;
  for (const t of tokens) {
    if (t.trim().length > 0) n += 1;
  }
  return n;
}

function pushMerged(
  out: WordDiffToken[],
  kind: "equal" | "added" | "removed",
  text: string
): void {
  const last = out[out.length - 1];
  if (last && last.kind === kind) {
    last.text += text;
  } else {
    out.push({ kind, text });
  }
}

export function computeWordDiff(
  before: string | null,
  after: string | null
): WordDiffResult {
  if (before === null && after === null) {
    return { tokens: [], addedWords: 0, removedWords: 0 };
  }
  if (before === null) {
    const aToks = tokenizeWords(after ?? "");
    return {
      tokens: after !== "" ? [{ kind: "added", text: after ?? "" }] : [],
      addedWords: countNonWs(aToks),
      removedWords: 0,
    };
  }
  if (after === null) {
    const bToks = tokenizeWords(before);
    return {
      tokens: before !== "" ? [{ kind: "removed", text: before }] : [],
      addedWords: 0,
      removedWords: countNonWs(bToks),
    };
  }
  if (before === after) {
    return {
      tokens: before ? [{ kind: "equal", text: before }] : [],
      addedWords: 0,
      removedWords: 0,
    };
  }

  const a = tokenizeWords(before);
  const b = tokenizeWords(after);
  const m = a.length;
  const n = b.length;

  if (m * n > 250000) {
    return {
      tokens: [
        ...(before ? [{ kind: "removed" as const, text: before }] : []),
        ...(after ? [{ kind: "added" as const, text: after }] : []),
      ],
      addedWords: countNonWs(b),
      removedWords: countNonWs(a),
    };
  }

  const dp: number[][] = Array.from({ length: m + 1 }, () =>
    new Array<number>(n + 1).fill(0)
  );
  for (let i = m - 1; i >= 0; i -= 1) {
    for (let j = n - 1; j >= 0; j -= 1) {
      if (a[i] === b[j]) {
        dp[i][j] = 1 + dp[i + 1][j + 1];
      } else {
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }

  const out: WordDiffToken[] = [];
  let addedWords = 0;
  let removedWords = 0;
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (a[i] === b[j]) {
      pushMerged(out, "equal", a[i]);
      i += 1;
      j += 1;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      pushMerged(out, "removed", a[i]);
      if (a[i].trim().length > 0) removedWords += 1;
      i += 1;
    } else {
      pushMerged(out, "added", b[j]);
      if (b[j].trim().length > 0) addedWords += 1;
      j += 1;
    }
  }
  while (i < m) {
    pushMerged(out, "removed", a[i]);
    if (a[i].trim().length > 0) removedWords += 1;
    i += 1;
  }
  while (j < n) {
    pushMerged(out, "added", b[j]);
    if (b[j].trim().length > 0) addedWords += 1;
    j += 1;
  }

  return { tokens: out, addedWords, removedWords };
}

export function formatDiffMagnitude(diff: ProposalDiffResponse): string {
  const parts: string[] = [];
  const blockDiffs = diff.block_diffs ?? [];
  const rowDiffs = diff.db_row_diffs ?? [];
  const schemaDiffs = diff.db_schema_diffs ?? [];
  const changedDeltas = (diff.rollup_deltas ?? []).filter((d) => d.changed);

  if (blockDiffs.length > 0) {
    let addW = 0;
    let remW = 0;
    for (const bd of blockDiffs) {
      const wd = computeWordDiff(bd.before_markdown, bd.after_markdown);
      addW += wd.addedWords;
      remW += wd.removedWords;
    }
    parts.push(
      `${blockDiffs.length} ${blockDiffs.length === 1 ? "block" : "blocks"} (+${addW}/-${remW} words)`
    );
  }
  if (rowDiffs.length > 0) {
    parts.push(`${rowDiffs.length} ${rowDiffs.length === 1 ? "row" : "rows"}`);
  }
  if (schemaDiffs.length > 0) {
    parts.push(`${schemaDiffs.length} schema`);
  }
  if (changedDeltas.length > 0) {
    const first = changedDeltas[0];
    parts.push(
      changedDeltas.length === 1
        ? `1 metric (${first.live_total} → ${first.scenario_total})`
        : `${changedDeltas.length} metrics`
    );
  }
  if (parts.length === 0) {
    return "No pending diff";
  }
  return parts.join(" · ");
}
