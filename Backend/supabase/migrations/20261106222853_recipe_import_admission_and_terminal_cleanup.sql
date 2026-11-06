-- One accepted import_id creates one queued job and consumes quota once.
-- Queue input is removed in the same transaction that makes a job terminal,
-- including reclaim/dead-letter paths that do not run the Edge handler.
CREATE INDEX IF NOT EXISTS idx_notification_jobs_recipe_import_id
  ON public.notification_jobs (canonical_user_key, (lower(payload_json->>'import_id')))
  WHERE kind = 'recipe_import_async';

CREATE OR REPLACE FUNCTION public.stir_enqueue_recipe_import(
  p_canonical_user_key TEXT,
  p_import_id UUID,
  p_period_start DATE,
  p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_job public.notification_jobs%ROWTYPE;
  v_quota RECORD;
BEGIN
  IF lower(p_payload->>'import_id') IS DISTINCT FROM p_import_id::TEXT
     OR jsonb_typeof(p_payload->'raw_content') IS DISTINCT FROM 'string'
     OR octet_length(p_payload->>'raw_content') > 2097152 THEN
    RAISE EXCEPTION 'invalid recipe import payload' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_canonical_user_key || ':recipe-import:' || p_import_id::TEXT, 0)
  );
  SELECT * INTO v_job FROM public.notification_jobs
   WHERE canonical_user_key = p_canonical_user_key
     AND kind = 'recipe_import_async'
     AND lower(payload_json->>'import_id') = p_import_id::TEXT
   ORDER BY created_at ASC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'existing', 'job_id', v_job.id, 'job_state', v_job.state);
  END IF;

  SELECT * INTO v_quota FROM public.stir_increment_usage_counter(
    p_canonical_user_key, p_period_start, 'recipe_import'::public.usage_feature_key
  );
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_bootstrapped'); END IF;
  IF v_quota.status <> 'allowed' THEN
    RETURN jsonb_build_object('status', v_quota.status, 'used', v_quota.used_count, 'cap', v_quota.cap_count);
  END IF;

  INSERT INTO public.notification_jobs(canonical_user_key, kind, state, payload_json)
    VALUES(p_canonical_user_key, 'recipe_import_async', 'pending', p_payload - 'original_url')
    RETURNING * INTO v_job;
  RETURN jsonb_build_object('status', 'queued', 'job_id', v_job.id, 'job_state', v_job.state);
END;
$$;
REVOKE ALL ON FUNCTION public.stir_enqueue_recipe_import(TEXT, UUID, DATE, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_enqueue_recipe_import(TEXT, UUID, DATE, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.stir_clear_terminal_import_payload()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NEW.kind = 'recipe_import_async' AND NEW.state IN ('completed', 'failed') THEN
    NEW.payload_json := NEW.payload_json - 'raw_content' - 'original_url';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.stir_clear_terminal_import_payload() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS clear_terminal_import_payload ON public.notification_jobs;
CREATE TRIGGER clear_terminal_import_payload
  BEFORE INSERT OR UPDATE ON public.notification_jobs
  FOR EACH ROW EXECUTE FUNCTION public.stir_clear_terminal_import_payload();

UPDATE public.notification_jobs
   SET payload_json = payload_json - 'raw_content' - 'original_url'
 WHERE kind = 'recipe_import_async' AND state IN ('completed', 'failed')
   AND (payload_json ? 'raw_content' OR payload_json ? 'original_url');
