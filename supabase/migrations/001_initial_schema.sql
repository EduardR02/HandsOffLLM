-- HandsOffLLM Initial Schema Migration
-- Creates tables for usage tracking and user limits

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

-- Indexes for fast queries
CREATE INDEX IF NOT EXISTS idx_usage_logs_user_timestamp ON usage_logs(user_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_user_provider ON usage_logs(user_id, provider, timestamp DESC);

-- Enable Row Level Security
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

-- Function to create default user limits on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_limits (user_id, monthly_limit_usd)
  VALUES (NEW.id, 8.00);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to automatically create user limits
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Function to get current month usage
CREATE OR REPLACE FUNCTION public.get_current_month_usage(p_user_id UUID)
RETURNS DECIMAL AS $$
  SELECT COALESCE(SUM(cost_usd), 0)
  FROM usage_logs
  WHERE user_id = p_user_id
    AND timestamp >= date_trunc('month', NOW())
    AND timestamp < date_trunc('month', NOW()) + INTERVAL '1 month';
$$ LANGUAGE sql SECURITY DEFINER;
