-- Rate limiting: Track recent requests per user
CREATE TABLE IF NOT EXISTS rate_limit_log (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  request_timestamp TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Simple composite index supports recent-lookups without non-immutable predicates
CREATE INDEX IF NOT EXISTS idx_rate_limit_recent
  ON rate_limit_log(user_id, request_timestamp DESC);

-- Function to check rate limit (10 requests per minute)
CREATE OR REPLACE FUNCTION public.check_rate_limit(p_user_id UUID, p_max_requests INT DEFAULT 10)
RETURNS BOOLEAN AS $$
DECLARE
  recent_count INT;
BEGIN
  -- Count requests in last minute
  SELECT COUNT(*) INTO recent_count
  FROM rate_limit_log
  WHERE user_id = p_user_id
    AND request_timestamp >= NOW() - INTERVAL '1 minute';

  -- Insert current request
  INSERT INTO rate_limit_log (user_id) VALUES (p_user_id);

  -- Return true if under limit
  RETURN recent_count < p_max_requests;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cleanup job: Delete old rate limit logs (run via pg_cron or manual cleanup)
-- DELETE FROM rate_limit_log WHERE request_timestamp < NOW() - INTERVAL '5 minutes';
