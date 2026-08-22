-- Migration: Add extension_page_load_ms column to search_traces
-- This stores the time spent loading Google's search results page
-- (from user pressing Enter to page fully loaded)

ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS extension_page_load_ms INTEGER;

-- Comment explaining the timing breakdown:
-- extension_total_flow_ms = Total time from user pressing Enter to notification showing
-- extension_page_load_ms = Time for Google page to load (network + Google server + render)
-- extension_settings_check_ms = Time to check user settings (after page load)
-- extension_backend_search_ms = Time for our backend search call (client-side view, includes network)
-- extension_notification_ms = Time to show notification
-- extension_delay_ms = Intentional delay before notification

COMMENT ON COLUMN search_traces.extension_page_load_ms IS 'Time for Google search page to load (ms) - from navigation start to page complete';
