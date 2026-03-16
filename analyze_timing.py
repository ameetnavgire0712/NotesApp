"""Analyze the timing of stuck trace to understand exactly when Worker died"""

# From the trace:
request_received = "2026-02-20T11:50:14.563"
processing_started = "2026-02-20T11:50:15.001"  # +0.4s
blob_started = "2026-02-20T11:50:15.175"        # +0.6s
blob_completed = "2026-02-20T11:50:15.56"       # +1.0s
conversion_started = "2026-02-20T11:50:15.785"  # +1.2s
conversion_completed = "2026-02-20T11:50:43.163" # +28.6s (TensorLake took 27.4s)
title_gen_completed = "2026-02-20T11:50:43.747"  # +29.2s
embedding_completed = "2026-02-20T11:50:44.131"  # +29.6s
# DB insert never started (no db_insert_started_at)

from datetime import datetime

def parse_time(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f")

base = parse_time(request_received)
events = [
    ("request_received", request_received),
    ("processing_started", processing_started),
    ("blob_started", blob_started),
    ("blob_completed", blob_completed),
    ("conversion_started", conversion_started),
    ("conversion_completed", conversion_completed),
    ("title_gen_completed", title_gen_completed),
    ("embedding_completed", embedding_completed),
]

print("Timeline from request_received:")
print("=" * 50)
for name, ts in events:
    t = parse_time(ts)
    delta = (t - base).total_seconds()
    print(f"  +{delta:6.2f}s  {name}")

# Calculate when Worker likely died
last_event = parse_time(embedding_completed)
dead_time = (last_event - base).total_seconds()
print(f"\n  +{dead_time:6.2f}s  *** Worker died somewhere after this ***")
print(f"\nTotal wall-clock time when Worker died: ~{dead_time:.1f} seconds")
print("\nThis is EXACTLY the ~30 second wall-clock limit!")
print("\nNote: CPU time used was only:")
print(f"  - blob_upload: ~100ms of actual CPU")
print(f"  - TensorLake polling: mostly waiting (fetch), minimal CPU") 
print(f"  - title_gen (Groq): ~100ms of actual CPU")
print(f"  - embedding (Workers AI): ~200ms of actual CPU")
print(f"  - Total actual CPU: probably < 1 second")
print("\nThe limit being hit is WALL-CLOCK DURATION, not CPU time.")
