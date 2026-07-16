import { mkdir, rename, writeFile } from "node:fs/promises";

const stateDir = process.env.STATE_DIR || "/state";
const repositoryUrl = process.env.GITHUB_REPOSITORY_URL || "https://github.com/mho747/wardrobe.git";
const branch = process.env.GITHUB_BRANCH || "main";
const deployedRevision = process.env.WARDROBE_REVISION || "unknown";
const interval = Number.parseInt(process.env.UPDATE_CHECK_INTERVAL_SECONDS || "86400", 10);
const runOnce = process.env.UPDATE_CHECK_ONCE === "1";

if (!Number.isSafeInteger(interval) || interval <= 0) {
  throw new Error("UPDATE_CHECK_INTERVAL_SECONDS must be a positive integer.");
}

function repositoryPath(url) {
  const match = url.match(/^https:\/\/github\.com\/([^/]+\/[^/]+?)(?:\.git)?\/?$/i);
  if (!match) throw new Error("GITHUB_REPOSITORY_URL must be an HTTPS GitHub repository URL.");
  return match[1];
}

async function writeStatus(value) {
  const temporary = `${stateDir}/update-status.json.partial`;
  await writeFile(temporary, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  await rename(temporary, `${stateDir}/update-status.json`);
}

async function checkOnce() {
  const checkedAt = new Date().toISOString();
  try {
    const response = await fetch(`https://api.github.com/repos/${repositoryPath(repositoryUrl)}/commits/${encodeURIComponent(branch)}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "wardrobe-update-check" },
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) throw new Error(`GitHub returned HTTP ${response.status}`);
    const payload = await response.json();
    if (typeof payload.sha !== "string" || !/^[0-9a-f]{40}$/i.test(payload.sha)) throw new Error("GitHub returned no valid commit SHA.");
    await writeStatus({
      checked_at: checkedAt,
      status: payload.sha === deployedRevision ? "current" : "update_available",
      deployed_revision: deployedRevision,
      remote_revision: payload.sha,
      branch,
    });
  } catch (error) {
    await writeStatus({ checked_at: checkedAt, status: "check_failed", detail: error instanceof Error ? error.message : "Unknown error" });
  }
}

await mkdir(stateDir, { recursive: true, mode: 0o700 });
do {
  await checkOnce();
  if (runOnce) break;
  await new Promise((resolve) => setTimeout(resolve, interval * 1_000));
} while (true);
