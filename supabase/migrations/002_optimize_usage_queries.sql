-- Existing idx_usage_logs_user_timestamp already covers user/month scans; no extra index.

-- Optimization: Combined function to get usage + limit in one query
CREATE OR REPLACE FUNCTION public.check_user_quota(p_user_id UUID)
RETURNS TABLE(current_usage DECIMAL, monthly_limit DECIMAL, quota_exceeded BOOLEAN) AS $$
  WITH monthly_usage AS (
    SELECT COALESCE(SUM(cost_usd), 0) as usage
    FROM usage_logs
    WHERE user_id = p_user_id
      AND date_trunc('month', timestamp) = date_trunc('month', NOW())
  ),
  user_limit AS (
    SELECT COALESCE(monthly_limit_usd, 8.00) as limit
    FROM user_limits
    WHERE user_id = p_user_id
  )
  SELECT
    monthly_usage.usage as current_usage,
    user_limit.limit as monthly_limit,
    monthly_usage.usage >= user_limit.limit as quota_exceeded
  FROM monthly_usage, user_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
