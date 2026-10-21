// semver.mjs — the one place that compares dotted version strings.
// Tolerant by design: input that is not shaped like major.minor.patch never
// compares as newer (returns false), and trailing prerelease/build parts are
// ignored. The shell-side twin of this check (node -e in server.mjs's
// REMOTE_PI_SCRIPT, run on the remote host) must stay in step.
function parts(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v ?? '').trim());
  return m ? m.slice(1).map(Number) : null;
}

/** true when `b` is strictly newer than `a`; false when either side is missing or unparseable. */
export function semverNewer(a, b) {
  const A = parts(a), B = parts(b);
  if (!A || !B) return false;
  for (let i = 0; i < 3; i++) {
    if (B[i] > A[i]) return true;
    if (B[i] < A[i]) return false;
  }
  return false;
}

/** true when `v` is at least `min` (inclusive); false when unparseable. */
export function semverAtLeast(v, min) {
  if (!parts(v) || !parts(min)) return false;
  return !semverNewer(v, min); // !(min strictly newer than v) ⇒ v >= min
}
