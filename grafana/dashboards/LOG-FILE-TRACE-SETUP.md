# Log File Trace Dashboard Setup

This dashboard allows you to view detailed logs from `notesapp.log` directly in Grafana by calling the API endpoint.

## Prerequisites

1. **Infinity Plugin** - Must be installed in Grafana
   - Go to: Configuration → Plugins → Search "Infinity" → Install `yesoreyeram-infinity-datasource`

2. **Infinity Data Source** - Create one:
   - Go to: Configuration → Data Sources → Add data source
   - Search for "Infinity" and select it
   - Name it: `Infinity` (or any name)
   - Click "Save & Test"

## Import the Dashboard

1. Go to: Dashboards → New → Import
2. Upload: `grafana/dashboards/notesapp-log-file-trace.json`
3. Select your Infinity data source when prompted
4. Click Import

## Configure Variables

After import, go to Dashboard Settings → Variables:

1. **api_base_url**: Set to your NotesApp API URL
   - Local: `http://localhost:8000`
   - Production: `https://your-api.example.com`

2. **infinity_ds**: Should auto-detect your Infinity data source

## Usage

### From Search Deep-Dive Dashboard
1. Open "NotesApp - Search Deep-Dive" dashboard
2. In the "Recent Search Queries" table, click any `correlation_id`
3. Select "📋 View Detailed Logs (File)" 
4. The Log File Trace dashboard opens with all logs for that request

### Direct Access
1. Open "NotesApp - Log File Trace" dashboard
2. Enter a correlation_id in the variable box at the top
3. Press Enter to load logs

## What You'll See

- **Summary Stats**: Total lines, duration, start time, log level counts
- **Detailed Log Table**: All log entries in chronological order including:
  - Authentication steps
  - FAISS vector search scores
  - Hybrid search candidate filtering
  - Reranker decisions
  - Response generation steps
  - Any errors or warnings

## Troubleshooting

### "No data" shown
- Ensure your NotesApp server is running
- Check `api_base_url` variable is correct
- Verify the Infinity data source can reach the API

### CORS errors
- The API should allow requests from your Grafana domain
- Check browser console for specific errors

### Infinity plugin not working
- Ensure plugin is installed and data source is configured
- Try creating a simple test panel first
