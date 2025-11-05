-- Ensure the user_limits read policy exists without failing if already present
DO $$
BEGIN
  CREATE POLICY "Users can read own limits"
    ON user_limits FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN
    -- Policy already exists; nothing to do
    NULL;
END;
$$;
