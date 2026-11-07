-- A queued import has ten minutes to finish. Postgres cleanup continues even
-- when the Edge dispatcher is down. Completion and expiry serialize on the job.
CREATE INDEX IF NOT EXISTS idx_recipe_import_live_deadline
  ON public.notification_jobs (created_at)
  WHERE kind = 'recipe_import_async' AND state IN ('pending', 'processing');

CREATE FUNCTION public.stir_guard_recipe_import_deadline()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NEW.kind <> 'recipe_import_async' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.state = 'failed' AND OLD.error_message = 'IMPORT_EXPIRED' THEN
    NEW.state := 'failed';
    NEW.error_message := 'IMPORT_EXPIRED';
  ELSIF NEW.state IN ('pending', 'processing') AND NEW.created_at <= now() - INTERVAL '10 minutes' THEN
    NEW.state := 'failed';
    NEW.error_message := 'IMPORT_EXPIRED';
    NEW.processed_at := now();
  END IF;
  IF NEW.state IN ('completed', 'failed') THEN
    NEW.payload_json := NEW.payload_json - 'raw_content' - 'original_url';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.stir_guard_recipe_import_deadline() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER guard_recipe_import_deadline BEFORE INSERT OR UPDATE ON public.notification_jobs
  FOR EACH ROW EXECUTE FUNCTION public.stir_guard_recipe_import_deadline();

CREATE FUNCTION public.stir_expire_recipe_imports()
RETURNS INTEGER LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_count INTEGER;
BEGIN
  UPDATE public.notification_jobs
     SET state = 'failed', error_message = 'IMPORT_EXPIRED', processed_at = now(), updated_at = now()
   WHERE kind = 'recipe_import_async' AND state IN ('pending', 'processing')
     AND created_at <= now() - INTERVAL '10 minutes';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.stir_expire_recipe_imports() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_expire_recipe_imports() TO service_role;
SELECT cron.schedule('recipe-import-expiry', '* * * * *', 'SELECT public.stir_expire_recipe_imports();');
SELECT public.stir_expire_recipe_imports();

CREATE FUNCTION public.stir_complete_recipe_import(p_job_id UUID, p_response JSONB)
RETURNS TEXT LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_job public.notification_jobs%ROWTYPE;
BEGIN
  SELECT * INTO v_job FROM public.notification_jobs WHERE id = p_job_id AND kind = 'recipe_import_async' FOR UPDATE;
  IF NOT FOUND THEN RETURN 'expired'; END IF;
  IF v_job.state = 'completed' THEN RETURN 'completed'; END IF;
  IF v_job.state <> 'processing' OR v_job.created_at <= now() - INTERVAL '10 minutes' THEN
    IF v_job.state IN ('pending', 'processing') THEN
      UPDATE public.notification_jobs SET state = 'failed', error_message = 'IMPORT_EXPIRED',
        processed_at = now(), updated_at = now() WHERE id = p_job_id;
    END IF;
    RETURN 'expired';
  END IF;
  IF p_response->>'import_id' IS DISTINCT FROM v_job.payload_json->>'import_id'
     OR p_response->>'status' IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'invalid recipe completion' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.ai_response_cache(canonical_user_key, request_id, feature_key, status_code, response_body)
    VALUES(v_job.canonical_user_key, (v_job.payload_json->>'import_id')::UUID, 'recipe_import', 200, p_response)
    ON CONFLICT (canonical_user_key, request_id) DO NOTHING;
  UPDATE public.notification_jobs SET state = 'completed', processed_at = now(), updated_at = now() WHERE id = p_job_id;
  RETURN 'completed';
END;
$$;
REVOKE ALL ON FUNCTION public.stir_complete_recipe_import(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_complete_recipe_import(UUID, JSONB) TO service_role;
