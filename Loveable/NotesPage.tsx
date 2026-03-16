import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { FileText, Image, File, Calendar, Tag, Search, ExternalLink, StickyNote } from "lucide-react";
import { motion } from "framer-motion";
import { format, isToday, isYesterday } from "date-fns";

interface Note {
  id: string;
  title: string;
  content_markdown?: string;
  file_type?: string;
  tag?: string | null;
  created_at: string;
  blob_url?: string;
  original_filename?: string;
}

type ViewMode = "date" | "tags";

const API_URL = "https://notesapp-gateway.monocle0712.workers.dev/api/v1/notes/";
const API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU";

async function fetchNotes(params: { limit?: number; offset?: number; tag?: string; file_type?: string }) {
  const url = new URL(API_URL);
  if (params.limit) url.searchParams.set("limit", String(params.limit));
  if (params.offset) url.searchParams.set("offset", String(params.offset));
  if (params.tag) url.searchParams.set("tag", params.tag);
  if (params.file_type) url.searchParams.set("file_type", params.file_type);

  const res = await fetch(url.toString(), {
    headers: { "X-API-Key": API_KEY },
  });
  if (!res.ok) throw new Error("Failed to fetch notes");
  return res.json();
}

function getFileIcon(fileType?: string) {
  if (!fileType) return File;
  if (fileType.includes("pdf")) return FileText;
  if (fileType.includes("image")) return Image;
  if (fileType.includes("quick_note")) return StickyNote;
  return File;
}

function formatDayLabel(dateStr: string): string {
  const date = new Date(dateStr);
  if (isToday(date)) return "Today";
  if (isYesterday(date)) return "Yesterday";
  return format(date, "EEEE, MMMM d, yyyy");
}

function NoteCard({ note, index }: { note: Note; index: number }) {
  const Icon = getFileIcon(note.file_type);
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: index * 0.03 }}
      className="bg-card border border-border rounded-xl p-5 hover:shadow-md hover:border-accent/30 transition-all group cursor-pointer"
    >
      <div className="flex items-start justify-between mb-3">
        <div className="w-9 h-9 rounded-lg bg-secondary flex items-center justify-center">
          <Icon className="w-4 h-4 text-accent" />
        </div>
        <div className="flex items-center gap-2">
          {note.tag && (
            <span className="text-[10px] font-medium bg-secondary text-muted-foreground px-1.5 py-0.5 rounded">
              {note.tag}
            </span>
          )}
          {note.blob_url && (
            <a
              href={note.blob_url}
              target="_blank"
              rel="noopener noreferrer"
              className="opacity-0 group-hover:opacity-100 transition-opacity"
              onClick={(e) => e.stopPropagation()}
            >
              <ExternalLink className="w-4 h-4 text-muted-foreground hover:text-foreground" />
            </a>
          )}
        </div>
      </div>
      <h3 className="font-medium text-sm text-foreground mb-1 line-clamp-2">
        {note.title || note.original_filename || "Untitled"}
      </h3>
      {note.content_markdown && (
        <p className="text-xs text-muted-foreground line-clamp-2 mb-3">{note.content_markdown}</p>
      )}
      <div className="flex items-center justify-between mt-auto">
        <span className="text-[11px] text-muted-foreground">
          {format(new Date(note.created_at), "MMM d, yyyy · h:mm a")}
        </span>
        {note.file_type && (
          <span className="text-[10px] font-medium text-muted-foreground/60 uppercase">
            {note.file_type.replace("_", " ")}
          </span>
        )}
      </div>
    </motion.div>
  );
}

export default function NotesPage() {
  const [viewMode, setViewMode] = useState<ViewMode>("date");
  const [searchQuery, setSearchQuery] = useState("");

  const { data, isLoading, error } = useQuery({
    queryKey: ["notes"],
    queryFn: () => fetchNotes({ limit: 100, offset: 0 }),
  });

  const notes: Note[] = Array.isArray(data) ? data : [];

  // Filter by search
  const filtered = notes.filter(
    (n) =>
      !searchQuery ||
      n.title?.toLowerCase().includes(searchQuery.toLowerCase()) ||
      n.content_markdown?.toLowerCase().includes(searchQuery.toLowerCase()) ||
      n.tag?.toLowerCase().includes(searchQuery.toLowerCase())
  );

  // Group by date (day)
  const groupedByDate = filtered
    .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    .reduce<Record<string, Note[]>>((acc, note) => {
      const dayKey = format(new Date(note.created_at), "yyyy-MM-dd");
      if (!acc[dayKey]) acc[dayKey] = [];
      acc[dayKey].push(note);
      return acc;
    }, {});

  // Group by tag
  const groupedByTag = filtered
    .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    .reduce<Record<string, Note[]>>((acc, note) => {
      const tagKey = note.tag || "Untagged";
      if (!acc[tagKey]) acc[tagKey] = [];
      acc[tagKey].push(note);
      return acc;
    }, {});

  const groups = viewMode === "date" ? groupedByDate : groupedByTag;
  const groupKeys = Object.keys(groups);

  // For date view, sort keys descending; for tags, sort alphabetically with "Untagged" last
  const sortedKeys =
    viewMode === "date"
      ? groupKeys.sort((a, b) => b.localeCompare(a))
      : groupKeys.sort((a, b) => {
          if (a === "Untagged") return 1;
          if (b === "Untagged") return -1;
          return a.localeCompare(b);
        });

  return (
    <div className="flex flex-col h-screen">
      {/* Header */}
      <header className="border-b border-border px-8 py-4 bg-card/80 backdrop-blur-sm">
        <h1 className="font-display text-2xl font-semibold text-foreground">Your Notes</h1>
        <p className="text-sm text-muted-foreground mt-1">All your saved documents in one place</p>
      </header>

      {/* Toolbar */}
      <div className="px-8 py-4 flex flex-wrap items-center gap-3 border-b border-border bg-card/40">
        {/* Search */}
        <div className="relative flex-1 min-w-[200px] max-w-sm">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
          <input
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Search notes..."
            className="w-full pl-9 pr-4 py-2 rounded-lg border border-border bg-background text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-accent/30 focus:border-accent/50 transition-all"
          />
        </div>

        {/* View toggle */}
        <div className="flex items-center gap-1 bg-secondary rounded-lg p-1">
          <button
            onClick={() => setViewMode("date")}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all ${
              viewMode === "date"
                ? "bg-card text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Calendar className="w-3.5 h-3.5" />
            Date
          </button>
          <button
            onClick={() => setViewMode("tags")}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all ${
              viewMode === "tags"
                ? "bg-card text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Tag className="w-3.5 h-3.5" />
            Tags
          </button>
        </div>
      </div>

      {/* Notes list */}
      <div className="flex-1 overflow-y-auto chat-scroll px-8 py-6">
        {isLoading ? (
          <div className="space-y-6">
            {[...Array(3)].map((_, i) => (
              <div key={i}>
                <div className="h-4 bg-muted rounded w-32 mb-4" />
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                  {[...Array(3)].map((_, j) => (
                    <div key={j} className="bg-card border border-border rounded-xl p-5 animate-pulse">
                      <div className="h-4 bg-muted rounded w-3/4 mb-3" />
                      <div className="h-3 bg-muted rounded w-1/2 mb-2" />
                      <div className="h-3 bg-muted rounded w-1/3" />
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        ) : error ? (
          <div className="flex flex-col items-center justify-center h-64 text-center">
            <p className="text-destructive font-medium mb-1">Failed to load notes</p>
            <p className="text-sm text-muted-foreground">Please check your connection and try again.</p>
          </div>
        ) : sortedKeys.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-64 text-center">
            <FileText className="w-12 h-12 text-muted-foreground/30 mb-4" />
            <p className="text-muted-foreground font-medium">No notes found</p>
            <p className="text-sm text-muted-foreground mt-1">Upload a document to get started</p>
          </div>
        ) : (
          <div className="space-y-8">
            {sortedKeys.map((groupKey, gi) => (
              <motion.section
                key={groupKey}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ delay: gi * 0.05 }}
              >
                {/* Group header */}
                <div className="flex items-center gap-3 mb-4">
                  {viewMode === "date" ? (
                    <>
                      <div className="w-2 h-2 rounded-full bg-accent flex-shrink-0" />
                      <h2 className="text-sm font-semibold text-foreground">
                        {formatDayLabel(groupKey)}
                      </h2>
                      <span className="text-xs text-muted-foreground">
                        {groups[groupKey].length} {groups[groupKey].length === 1 ? "note" : "notes"}
                      </span>
                      <div className="flex-1 h-px bg-border" />
                    </>
                  ) : (
                    <>
                      <Tag className="w-3.5 h-3.5 text-accent flex-shrink-0" />
                      <h2 className="text-sm font-semibold text-foreground">{groupKey}</h2>
                      <span className="text-xs text-muted-foreground">
                        {groups[groupKey].length} {groups[groupKey].length === 1 ? "note" : "notes"}
                      </span>
                      <div className="flex-1 h-px bg-border" />
                    </>
                  )}
                </div>

                {/* Timeline connector for date view */}
                <div className={viewMode === "date" ? "relative pl-4 border-l-2 border-border ml-[3px]" : ""}>
                  <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                    {groups[groupKey].map((note, ni) => (
                      <NoteCard key={note.id} note={note} index={ni} />
                    ))}
                  </div>
                </div>
              </motion.section>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
