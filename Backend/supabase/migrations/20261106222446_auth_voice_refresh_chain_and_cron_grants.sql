-- Continuations are authorized by a ready, charged, bounded server-owned
-- chain. Legacy rows have no charged proof and cannot waive a new start.
ALTER TABLE public.voice_session_owners
  ADD COLUMN cooking_session_id uuid,
  ADD COLUMN root_started_at timestamptz,
  ADD COLUMN quota_charged_at timestamptz,
  ADD COLUMN ready_at timestamptz,
  ADD COLUMN predecessor_session_id uuid;

CREATE FUNCTION public.stir_voice_session_claim(
  p_session_id uuid, p_canonical_user_key text, p_cooking_session_id uuid,
  p_is_refresh boolean
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_previous public.voice_session_owners%ROWTYPE;
  v_now timestamptz := now();
BEGIN
  -- Serialize both charged starts and continuations for this account.
  PERFORM 1 FROM public.app_users WHERE canonical_user_key = p_canonical_user_key
    AND status = 'active' AND merged_into IS NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO v_previous FROM public.voice_session_owners
    WHERE canonical_user_key = p_canonical_user_key AND closed_at IS NULL FOR UPDATE;
  IF p_is_refresh AND (
    v_previous.session_id IS NULL OR v_previous.ready_at IS NULL
    OR v_previous.cooking_session_id IS DISTINCT FROM p_cooking_session_id
    OR v_previous.quota_charged_at IS NULL
    OR v_previous.root_started_at < v_now - interval '2 hours'
    OR v_previous.minted_at < v_now - interval '65 minutes'
  ) THEN RETURN false; END IF;
  -- A pending successor cannot itself authorize another exempt mint.
  UPDATE public.voice_session_owners SET closed_at = v_now
    WHERE canonical_user_key = p_canonical_user_key AND closed_at IS NULL;
  INSERT INTO public.voice_session_owners (
    session_id, canonical_user_key, cooking_session_id, root_started_at,
    quota_charged_at, predecessor_session_id
  ) VALUES (
    p_session_id, p_canonical_user_key, p_cooking_session_id,
    CASE WHEN p_is_refresh THEN v_previous.root_started_at ELSE v_now END,
    CASE WHEN p_is_refresh THEN v_previous.quota_charged_at ELSE v_now END,
    v_previous.session_id
  );
  RETURN true;
END $$;

CREATE FUNCTION public.stir_voice_session_ready(p_session_id uuid, p_canonical_user_key text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM 1 FROM public.app_users WHERE canonical_user_key = p_canonical_user_key FOR UPDATE;
  UPDATE public.voice_session_owners SET ready_at = now()
    WHERE session_id = p_session_id AND canonical_user_key = p_canonical_user_key
      AND closed_at IS NULL AND ready_at IS NULL;
  RETURN FOUND;
END $$;

CREATE FUNCTION public.stir_voice_session_abort(p_session_id uuid, p_canonical_user_key text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_previous uuid; v_was_open boolean;
BEGIN
  PERFORM 1 FROM public.app_users WHERE canonical_user_key = p_canonical_user_key FOR UPDATE;
  DELETE FROM public.voice_session_owners
    WHERE session_id = p_session_id AND canonical_user_key = p_canonical_user_key
      AND ready_at IS NULL
    RETURNING predecessor_session_id, closed_at IS NULL INTO v_previous, v_was_open;
  -- Restore only if this pending generation still owned the open slot.
  IF v_was_open AND NOT EXISTS (
    SELECT 1 FROM public.voice_session_owners
      WHERE canonical_user_key = p_canonical_user_key AND closed_at IS NULL
  ) THEN
    UPDATE public.voice_session_owners SET closed_at = NULL
      WHERE session_id = v_previous AND canonical_user_key = p_canonical_user_key;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.stir_voice_session_claim(uuid,text,uuid,boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stir_voice_session_ready(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stir_voice_session_abort(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_voice_session_claim(uuid,text,uuid,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_voice_session_ready(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_voice_session_abort(uuid,text) TO service_role;

-- Maintenance scheduling must not be callable through the public RPC API.
REVOKE ALL ON FUNCTION public._register_pgmq_dispatch_cron() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._register_pgmq_dispatch_cron() TO service_role;
