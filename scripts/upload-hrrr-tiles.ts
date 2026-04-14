/**
 * Upload HRRR forecast tiles to AWS S3 and rotate old runs.
 *
 * Usage:
 *   npx tsx scripts/upload-hrrr-tiles.ts                 # upload latest run
 *   npx tsx scripts/upload-hrrr-tiles.ts --all           # upload all local runs
 *   npx tsx scripts/upload-hrrr-tiles.ts --keep 2        # keep 2 most recent runs (default)
 *
 * On EC2 the instance profile provides credentials automatically.
 * Locally set AWS_PROFILE or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
 * Requires S3_FORECAST_BUCKET and CLOUDFRONT_FORECAST_URL in .env.
 */

import {
  PutObjectCommand,
  ListObjectsV2Command,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { readFileSync, readdirSync, statSync } from 'fs';
import { join, resolve } from 'path';
import { config } from 'dotenv';
import { createS3Client, S3_BUCKETS, S3_PUBLIC_URLS } from '../lib/s3-client';

// Load env from repo root .env
config({ path: resolve(__dirname, '..', '.env') });

const BUCKET = S3_BUCKETS.forecastTiles;
const TILES_ROOT = resolve(__dirname, 'output', 'hrrr-tiles');

const s3 = createS3Client();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** List local run directories (sorted newest first). Pattern: YYYYMMDDHH (10 digits). */
function listLocalRuns(): string[] {
  try {
    return readdirSync(TILES_ROOT)
      .filter((d) => /^\d{10}$/.test(d) && statSync(join(TILES_ROOT, d)).isDirectory())
      .sort()
      .reverse();
  } catch {
    return [];
  }
}

/** Recursively collect all file paths relative to the run directory. */
function collectFilePaths(runDir: string): string[] {
  const paths: string[] = [];

  function walk(dir: string, rel: string) {
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      const relPath = rel ? `${rel}/${entry}` : entry;
      if (statSync(full).isDirectory()) {
        walk(full, relPath);
      } else if (entry.endsWith('.png') || entry === 'manifest.json') {
        paths.push(relPath);
      }
    }
  }

  walk(runDir, '');
  return paths;
}

/** Upload a single run's tiles + manifest to S3. */
async function uploadRun(runId: string): Promise<number> {
  const runDir = join(TILES_ROOT, runId);
  const filePaths = collectFilePaths(runDir);
  console.log(`  Uploading ${filePaths.length} files for ${runId}...`);

  let uploaded = 0;
  let failed = 0;
  const BATCH_SIZE = 20;

  for (let i = 0; i < filePaths.length; i += BATCH_SIZE) {
    const batch = filePaths.slice(i, i + BATCH_SIZE);
    const results = await Promise.all(
      batch.map(async (relPath) => {
        const key = `${runId}/${relPath}`;
        const buffer = readFileSync(join(runDir, relPath));
        const contentType = relPath.endsWith('.json') ? 'application/json' : 'image/png';

        try {
          await s3.send(new PutObjectCommand({
            Bucket: BUCKET,
            Key: key,
            Body: buffer,
            ContentType: contentType,
            CacheControl: 'public, max-age=3600',
          }));
          return true;
        } catch (err) {
          console.warn(`    Failed: ${key} — ${err instanceof Error ? err.message : err}`);
          return false;
        }
      }),
    );

    uploaded += results.filter(Boolean).length;
    failed += results.filter((r) => !r).length;
  }

  console.log(`  Done: ${uploaded} uploaded, ${failed} failed`);
  return uploaded;
}

/** List remote run "directories" in S3 (top-level prefixes). */
async function listRemoteRuns(): Promise<string[]> {
  try {
    const response = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET,
      Delimiter: '/',
      MaxKeys: 100,
    }));

    return (response.CommonPrefixes ?? [])
      .map((p) => p.Prefix?.replace(/\/$/, '') ?? '')
      .filter((name) => /^\d{10}$/.test(name))
      .sort()
      .reverse();
  } catch (err) {
    console.warn('  Could not list remote runs:', err instanceof Error ? err.message : err);
    return [];
  }
}

/** Delete all files for a given run from S3. */
async function deleteRun(runId: string): Promise<void> {
  const allKeys: string[] = [];
  let continuationToken: string | undefined;

  do {
    const response = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET,
      Prefix: `${runId}/`,
      ContinuationToken: continuationToken,
    }));

    for (const obj of response.Contents ?? []) {
      if (obj.Key) allKeys.push(obj.Key);
    }

    continuationToken = response.IsTruncated ? response.NextContinuationToken : undefined;
  } while (continuationToken);

  if (allKeys.length === 0) return;

  for (let i = 0; i < allKeys.length; i += 1000) {
    const batch = allKeys.slice(i, i + 1000);
    await s3.send(new DeleteObjectsCommand({
      Bucket: BUCKET,
      Delete: { Objects: batch.map((Key) => ({ Key })) },
    }));
  }

  console.log(`  Deleted ${allKeys.length} files from ${runId}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  const uploadAll = args.includes('--all');
  const keepIndex = args.indexOf('--keep');
  const maxKeep = keepIndex >= 0 ? Number(args[keepIndex + 1]) : 2;

  console.log('HRRR Tile Uploader → AWS S3');
  console.log('============================\n');

  const localRuns = listLocalRuns();
  if (localRuns.length === 0) {
    console.error('No local HRRR runs found. Run generate-hrrr-tiles.ts first.');
    process.exit(1);
  }

  console.log(`Local runs: ${localRuns.join(', ')}`);

  const runsToUpload = uploadAll ? localRuns : [localRuns[0]];
  console.log(`\nUploading ${runsToUpload.length} run(s)...\n`);

  let totalFiles = 0;
  for (const runId of runsToUpload) {
    totalFiles += await uploadRun(runId);
  }

  console.log(`\nRotating old runs (keeping ${maxKeep} most recent)...`);
  const remoteRuns = await listRemoteRuns();
  console.log(`  Remote runs: ${remoteRuns.join(', ') || '(none)'}`);

  const toDelete = remoteRuns.slice(maxKeep);
  if (toDelete.length > 0) {
    for (const runId of toDelete) {
      await deleteRun(runId);
    }
  } else {
    console.log('  Nothing to rotate.');
  }

  const baseUrl = S3_PUBLIC_URLS.forecastTiles;
  console.log('\n============================');
  console.log(`Uploaded ${totalFiles} files total.`);
  console.log('\nPublic tile URL template:');
  console.log(`  ${baseUrl}/{run}/{z}/{x}/{y}.png`);
  console.log(`\nLatest run: ${runsToUpload[0]}`);
  console.log(`  ${baseUrl}/${runsToUpload[0]}/{z}/{x}/{y}.png`);
}

main().catch((err) => {
  console.error('\nFatal error:', err.message || err);
  process.exit(1);
});
