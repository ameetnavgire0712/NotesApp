# NotesApp Grafana Dashboard Setup Guide

This guide covers setting up Grafana to visualize NotesApp logs from both:
1. **Supabase PostgreSQL** - Real-time data (last 30 days)
2. **Azure Blob Storage CSV** - Archived data (older than 30 days)

## Prerequisites

- Grafana 9.0+ (Cloud or self-hosted)
- NotesApp with logging enabled
- Supabase project with log tables
- Azure Storage account with archived logs

---

## Part 1: Install Grafana Plugins

### Required Plugins

```bash
# If self-hosted Grafana
grafana-cli plugins install grafana-postgresql-datasource  # Usually pre-installed
grafana-cli plugins install yesoreyeram-infinity-datasource

# Restart Grafana after installation
sudo systemctl restart grafana-server
```

For Grafana Cloud:
1. Go to Administration → Plugins
2. Search for "Infinity" and install it
3. PostgreSQL is available by default

---

## Part 2: Configure PostgreSQL Data Source (Supabase)

### Step 1: Get Supabase Connection Details

1. Go to your Supabase project dashboard
2. Navigate to **Settings → Database**
3. Copy the **Connection String** or individual values:
   - Host: `db.xxxxxxxxxxxx.supabase.co`
   - Port: `5432` (or `6543` for connection pooling)
   - Database: `postgres`
   - User: `postgres`
   - Password: Your database password

### Step 2: Add Data Source in Grafana

1. Go to **Connections → Data sources → Add data source**
2. Select **PostgreSQL**
3. Configure:
   ```
   Name: NotesApp Supabase
   Host: db.xxxxxxxxxxxx.supabase.co:5432
   Database: postgres
   User: postgres
   Password: [your-password]
   SSL Mode: require
   ```
4. Click **Save & Test**

### Step 3: Import Supabase Views

Run the SQL in `sql/grafana_views.sql` in your Supabase SQL Editor to create optimized views:
- `v_user_journey` - User activity timeline
- `v_api_metrics` - API latency and error rates
- `v_search_quality` - Search success metrics
- `v_chat_analytics` - Chat query patterns
- `v_error_analysis` - Error frequency
- And more...

---

## Part 3: Configure Infinity Data Source (Archived CSV)

### Step 1: Get CSV Archive URLs

Call the NotesApp API to get SAS URLs for archived files:

```bash
# List all archived CSV files
curl -X GET "http://localhost:8000/api/v1/logs/archive/csv" \
  -H "Authorization: Bearer YOUR_TOKEN"

# Get Grafana configuration
curl -X GET "http://localhost:8000/api/v1/logs/archive/grafana-config" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

Response example:
```json
{
  "files": [
    {
      "blob_name": "_grafana_archive/activities/2025-12-15.csv",
      "log_type": "activities",
      "date": "2025-12-15",
      "sas_url": "https://your-storage.blob.core.windows.net/...",
      "size_bytes": 45632
    }
  ]
}
```

### Step 2: Add Infinity Data Source

1. Go to **Connections → Data sources → Add data source**
2. Select **Infinity**
3. Configure:
   ```
   Name: NotesApp Archives
   Base URL: (leave empty, we'll use full URLs per query)
   ```
4. Click **Save & Test**

### Step 3: Create Archive Panels

When creating panels for archived data:

1. Select **NotesApp Archives** as data source
2. In query settings:
   ```
   Type: CSV
   Source: URL
   URL: [paste SAS URL from API]
   Format: Table
   ```
3. Add columns as needed

---

## Part 4: Dashboard Examples

### Dashboard 1: Overview (Real-time)

Create a new dashboard with these panels:

#### Panel 1.1: Daily Activity Summary
```sql
-- Data source: NotesApp Supabase
SELECT * FROM get_daily_summary(30);
```
Visualization: **Bar Chart** or **Table**

#### Panel 1.2: Real-time Activity Feed
```sql
SELECT * FROM v_realtime_activity;
```
Visualization: **Table** with auto-refresh (5s)

#### Panel 1.3: Error Rate Gauge
```sql
SELECT 
  ROUND(100.0 * SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate
FROM user_activities 
WHERE created_at >= NOW() - INTERVAL '1 hour';
```
Visualization: **Gauge** (thresholds: green <1%, yellow <5%, red ≥5%)

---

### Dashboard 2: API Performance

#### Panel 2.1: Latency Heatmap
```sql
SELECT 
  DATE_TRUNC('hour', created_at) as time,
  action,
  AVG(duration_ms) as avg_latency
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY 1, 2
ORDER BY 1;
```
Visualization: **Heatmap**

#### Panel 2.2: P95 Latency Trend
```sql
SELECT * FROM v_api_metrics 
WHERE hour >= NOW() - INTERVAL '7 days'
ORDER BY hour;
```
Visualization: **Time Series** (field: p95_latency_ms)

#### Panel 2.3: Requests by Action
```sql
SELECT 
  action,
  COUNT(*) as count
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY action
ORDER BY count DESC;
```
Visualization: **Pie Chart**

---

### Dashboard 3: Search & Chat Quality

#### Panel 3.1: Chat Success Rate
```sql
SELECT * FROM v_chat_analytics 
WHERE hour >= NOW() - INTERVAL '7 days';
```
Visualization: **Time Series** with calculated field for success rate

#### Panel 3.2: Sources Per Query
```sql
SELECT 
  DATE_TRUNC('hour', created_at) as time,
  AVG(source_count) as avg_sources
FROM v_chat_analytics
WHERE source_count IS NOT NULL
  AND created_at >= NOW() - INTERVAL '24 hours'
GROUP BY 1
ORDER BY 1;
```
Visualization: **Time Series**

#### Panel 3.3: Search Quality Metrics
```sql
SELECT * FROM v_search_quality ORDER BY day DESC LIMIT 30;
```
Visualization: **Table**

---

### Dashboard 4: User Analytics

#### Panel 4.1: Active Users Trend
```sql
SELECT 
  DATE_TRUNC('day', created_at) as day,
  COUNT(DISTINCT user_id) as unique_users
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1;
```
Visualization: **Time Series**

#### Panel 4.2: User Activity Heatmap
```sql
SELECT 
  EXTRACT(DOW FROM created_at) as day_of_week,
  EXTRACT(HOUR FROM created_at) as hour,
  COUNT(*) as activity_count
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY 1, 2;
```
Visualization: **Heatmap** (X: hour, Y: day_of_week)

#### Panel 4.3: Top Users
```sql
SELECT * FROM v_user_activity_summary 
ORDER BY total_actions DESC 
LIMIT 10;
```
Visualization: **Table** or **Bar Chart**

---

### Dashboard 5: Archived Data (Infinity Plugin)

For historical analysis beyond 30 days:

#### Panel 5.1: Historical Activity Table

1. Select **NotesApp Archives** data source
2. Configure query:
   ```
   Type: CSV
   Source: URL
   URL: [SAS URL for specific date]
   Format: Table
   ```

#### Panel 5.2: Multi-file Query

For querying across multiple archived files, use Grafana's **Mixed** data source
and add multiple Infinity queries, one per CSV file.

---

## Part 5: Alerting

### Alert 1: High Error Rate

```sql
SELECT 
  ROUND(100.0 * SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate
FROM user_activities 
WHERE created_at >= NOW() - INTERVAL '15 minutes';
```
- **Condition**: error_rate > 5
- **For**: 5 minutes
- **Notification**: Slack/Email/PagerDuty

### Alert 2: High Latency

```sql
SELECT 
  PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) as p95
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '15 minutes';
```
- **Condition**: p95 > 5000 (5 seconds)
- **For**: 10 minutes

### Alert 3: No Activity (Service Down)

```sql
SELECT COUNT(*) as activity_count
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '10 minutes';
```
- **Condition**: activity_count = 0
- **For**: 5 minutes

---

## Part 6: Best Practices

### Performance

1. **Use views**: Query the `v_*` views instead of raw tables
2. **Time filters**: Always include `WHERE created_at >= NOW() - INTERVAL 'X'`
3. **Index hints**: If slow, check indexes in `sql/grafana_views.sql`
4. **Refresh rates**: Don't set auto-refresh below 5 seconds for large queries

### Security

1. **Read-only user**: Create a dedicated Grafana user in Supabase with SELECT-only permissions
2. **SAS URLs**: The 1-year validity is for convenience; rotate if concerned
3. **Network**: Use VNet/Firewall rules to restrict Grafana's IP access

### Maintenance

1. **Archival job**: Ensure the archival job runs daily (30-day retention)
2. **CSV cleanup**: Old CSV files can be deleted after analysis period
3. **View updates**: Re-run `grafana_views.sql` after schema changes

---

## Troubleshooting

### "Connection refused" for PostgreSQL
- Check Supabase is not paused (free tier auto-pauses)
- Verify SSL mode is `require`
- Confirm port (5432 or 6543 for pooler)

### "No data" in Infinity plugin
- Verify SAS URL hasn't expired
- Check CSV file exists (call `/api/v1/logs/archive/csv`)
- Ensure archival job has run

### Slow queries
- Add suggested indexes from `grafana_views.sql`
- Use aggregated views instead of raw tables
- Reduce time range

---

## Quick Reference: View Summary

| View | Description | Use Case |
|------|-------------|----------|
| `v_user_journey` | All activities with metadata | Session analysis |
| `v_api_metrics` | Hourly aggregated metrics | Latency dashboards |
| `v_search_quality` | Search success rates | Search tuning |
| `v_chat_analytics` | Chat query details | Chat performance |
| `v_error_analysis` | Error frequency | Debugging |
| `v_operation_performance` | Backend service metrics | System health |
| `v_auth_activity` | Login/API key events | Security audit |
| `v_realtime_activity` | Last hour activity | Live monitoring |
| `get_daily_summary(N)` | Daily aggregates | Executive overview |

---

## Support

For issues with:
- **NotesApp logging**: Check `/api/v1/logs/` endpoints
- **Supabase connection**: Review Supabase dashboard → Database settings
- **Grafana plugins**: See plugin documentation
- **Archived data**: Verify blob storage container `_grafana_archive` folder
