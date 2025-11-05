-- HandsOffLLM Initial Schema Migration
-- Creates tables for usage tracking, user limits, and rate limiting

-- ============================================================================
-- TABLES
-- ============================================================================

-- User limits table
CREATE TABLE IF NOT EXISTS user_limits (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  monthly_limit_usd DECIMAL(10,2) DEFAULT 8.00 NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Granular usage logs (every API call)
CREATE TABLE IF NOT EXISTS usage_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,

  -- Token counts (nullable because not all providers report all types)
  cached_input_tokens INT DEFAULT 0,
  input_tokens INT DEFAULT 0,
  reasoning_output_tokens INT DEFAULT 0,
  output_tokens INT DEFAULT 0,

  -- Cost in USD
  cost_usd DECIMAL(10,6) NOT NULL,

  -- Metadata
  timestamp TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- ============================================================================
-- INDEXES
-- ============================================================================

-- Usage logs indexes for fast queries
CREATE INDEX IF NOT EXISTS idx_usage_logs_user_timestamp
  ON usage_logs(user_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_user_provider
  ON usage_logs(user_id, provider, timestamp DESC);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE user_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policies (drop first for idempotency)
DROP POLICY IF EXISTS "Users can read own limits" ON user_limits;
CREATE POLICY "Users can read own limits"
  ON user_limits FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own limits" ON user_limits;
CREATE POLICY "Users can insert own limits"
  ON user_limits FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own limits" ON user_limits;
CREATE POLICY "Users can update own limits"
  ON user_limits FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can read own usage logs" ON usage_logs;
CREATE POLICY "Users can read own usage logs"
  ON usage_logs FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Function to create default user limits on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_limits (user_id, monthly_limit_usd)
  VALUES (NEW.id, 8.00)
  ON CONFLICT (user_id) DO NOTHING;  -- Avoid errors on retry
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get current month usage (simple version for backward compatibility)
CREATE OR REPLACE FUNCTION public.get_current_month_usage(p_user_id UUID)
RETURNS DECIMAL AS $$
  SELECT COALESCE(SUM(cost_usd), 0)
  FROM usage_logs
  WHERE user_id = p_user_id
    AND timestamp >= date_trunc('month', NOW())
    AND timestamp < date_trunc('month', NOW()) + INTERVAL '1 month';
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Optimized function to check user quota (single query, handles missing limits gracefully)
CREATE OR REPLACE FUNCTION public.check_user_quota(p_user_id UUID)
RETURNS TABLE(current_usage DECIMAL, monthly_limit DECIMAL, quota_exceeded BOOLEAN) AS $$
  SELECT
    COALESCE(SUM(ul.cost_usd), 0) as current_usage,
    COALESCE(lim.monthly_limit_usd, 8.00) as monthly_limit,
    COALESCE(SUM(ul.cost_usd), 0) >= COALESCE(lim.monthly_limit_usd, 8.00) as quota_exceeded
  FROM (SELECT p_user_id as uid) u
  LEFT JOIN user_limits lim ON lim.user_id = u.uid
  LEFT JOIN usage_logs ul ON ul.user_id = u.uid
    AND ul.timestamp >= date_trunc('month', NOW())
    AND ul.timestamp < date_trunc('month', NOW()) + INTERVAL '1 month'
  GROUP BY lim.monthly_limit_usd;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Trigger to automatically create user limits on signup
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
