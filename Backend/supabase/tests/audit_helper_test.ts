// Step 8 — _shared/audit.ts writer tests.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { writeAudit } from '../functions/_shared/audit.ts';
import { serviceClient } from './_helpers/pg.ts';
import { createLogger } from '../functions/_shared/logger.ts';
import { seedAdmin } from './_helpers/admin_factory.ts';

async function testLogger() {
  return await createLogger(crypto.randomUUID(), '/test/audit');
}

Deno.test('writeAudit: happy path inserts row + returns id', async () => {
  const log = await testLogger();
  const svc = serviceClient();
  const admin = await seedAdmin();

  const uniqAction = 'test.write.' + crypto.randomUUID();
  const id = await writeAudit(svc, log, {
    actor_id: admin.authUserId,
    actor_email: admin.email,
    action: uniqAction,
    target_table: 'app_users',
    target_id: 'ck:test',
    before: { status: 'active' },
    after: { status: 'banned' },
    request_id: crypto.randomUUID(),
  });

  assertNotEquals(id, null);

  // Verify row is present with correct fields.
  const { data } = await svc
    .from('audit_log')
    .select('actor_id, actor_email, action, before_json, after_json, target_id')
    .eq('id', id!)
    .single();
  assertEquals(data?.actor_id, admin.authUserId);
  assertEquals(data?.actor_email, admin.email);
  assertEquals(data?.action, uniqAction);
  // PostgREST deserializes JSONB into typed values.
  assertEquals((data?.before_json as { status: string }).status, 'active');
  assertEquals((data?.after_json as { status: string }).status, 'banned');
});

Deno.test('writeAudit: null actor (system action) accepted', async () => {
  const log = await testLogger();
  const svc = serviceClient();

  const id = await writeAudit(svc, log, {
    actor_id: null,
    actor_email: null,
    action: 'system.cron.cost_anomaly_scan',
    target_table: 'cost_anomalies',
    target_id: 'cron-' + crypto.randomUUID(),
  });

  assertNotEquals(id, null);
});

Deno.test('writeAudit: insert failure returns null (does not throw)', async () => {
  const log = await testLogger();
  const svc = serviceClient();

  // Force a CHECK violation: action longer than 128 chars.
  const id = await writeAudit(svc, log, {
    actor_id: null,
    actor_email: null,
    action: 'x'.repeat(200),
    target_table: 'app_users',
    target_id: 'ck:test',
  });

  assertEquals(id, null);
});
