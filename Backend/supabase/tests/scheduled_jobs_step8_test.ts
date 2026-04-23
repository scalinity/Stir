// Step 8 Phase 1.6 — pg_cron scheduled jobs exist + are wired correctly.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';

type CronJob = {
  jobname: string;
  schedule: string;
  command: string;
  active: boolean;
};

async function fetchJob(name: string): Promise<CronJob | null> {
  const svc = serviceClient();
  // No direct SELECT on cron.job from the service-role client, but we can
  // exec via a SECURITY DEFINER wrapper. Simpler here: use the RPC-style
  // pattern with rpc on a custom helper. For the test we'll use raw SQL
  // via supabase-js's rpc pattern. Actually supabase-js doesn't expose
  // raw SQL; create a minimal SECURITY DEFINER helper locally and cache.
  const { data, error } = await svc.rpc('stir_ops_cron_job_info', { p_name: name });
  if (error) throw error;
  return (data as CronJob | null) ?? null;
}

Deno.test('pg_cron: stir-cost-anomaly-scan wired to 15-min schedule', async () => {
  const job = await fetchJob('stir-cost-anomaly-scan');
  assertNotEquals(job, null);
  assertEquals(job!.schedule, '*/15 * * * *');
  assertEquals(job!.active, true);
  assertEquals(job!.command.includes('stir_ops_cost_anomaly_scan'), true);
});

Deno.test('pg_cron: stir-reactivation-scan wired to daily 18:00 UTC', async () => {
  const job = await fetchJob('stir-reactivation-scan');
  assertNotEquals(job, null);
  assertEquals(job!.schedule, '0 18 * * *');
  assertEquals(job!.active, true);
  assertEquals(job!.command.includes('stir_ops_reactivation_enqueue'), true);
});

Deno.test('pg_cron: stir-audit-log-retention wired to nightly 09:30 UTC', async () => {
  const job = await fetchJob('stir-audit-log-retention');
  assertNotEquals(job, null);
  assertEquals(job!.schedule, '30 9 * * *');
  assertEquals(job!.active, true);
  assertEquals(job!.command.toLowerCase().includes('delete from public.audit_log'), true);
});
