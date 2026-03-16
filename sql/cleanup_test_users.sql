-- Cleanup test user data from activity logs
-- Keep only user_id: 2649b4d0-c40d-4ab1-ac04-928fe1cf5969
-- Run this in Supabase SQL Editor

-- Check what will be deleted (DRY RUN)
SELECT 'search_traces' as table_name, user_id, count(*) as count
FROM search_traces
WHERE user_id != '2649b4d0-c40d-4ab1-ac04-928fe1cf5969'
GROUP BY user_id
UNION ALL
SELECT 'upload_traces' as table_name, user_id, count(*) as count
FROM upload_traces
WHERE user_id != '2649b4d0-c40d-4ab1-ac04-928fe1cf5969'
GROUP BY user_id
ORDER BY table_name, user_id;

-- DELETE search traces for test users
DELETE FROM search_traces
WHERE user_id != '2649b4d0-c40d-4ab1-ac04-928fe1cf5969';

-- DELETE upload traces for test users
DELETE FROM upload_traces
WHERE user_id != '2649b4d0-c40d-4ab1-ac04-928fe1cf5969';

-- Verify cleanup
SELECT 'search_traces' as table_name, user_id, count(*) as count
FROM search_traces
GROUP BY user_id
UNION ALL
SELECT 'upload_traces' as table_name, user_id, count(*) as count
FROM upload_traces
GROUP BY user_id
ORDER BY table_name, user_id;
