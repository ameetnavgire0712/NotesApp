/**
 * Upload Processor Durable Object
 * 
 * Handles long-running upload processing with:
 * - State persistence across steps (resume on failure)
 * - Alarm-based polling for TensorLake (no timeout)
 * - Cancel upload support
 * - Progress tracking
 * 
 * Pipeline steps (saved after each):
 *   1. blob_upload - Upload file to Azure Blob Storage
 *   2. tensorlake_parse - Start TensorLake parse job
 *   3. tensorlake_poll - Poll TensorLake for completion (via alarms)
 *   4. html_cleanup - Clean HTML content (if needed)
 *   5. title_gen - Generate title with LLM
 *   6. chunking - Chunk the content
 *   7. embedding - Generate embeddings
 *   8. db_insert - Insert note into Supabase
 *   9. vectorize_upsert - Upsert vectors to Vectorize
 *   10. finalize - Cache invalidation and complete
 */

import { DurableObject } from 'cloudflare:workers';

// ============================================================================
// Types
// ============================================================================

export interface UploadProcessorEnv {
  AI: Ai;
  VECTORIZE: Vectorize;
  EMBEDDING_MODEL: string;
  GROQ_API_KEY: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  AZURE_STORAGE_CONNECTION_STRING: string;
  AZURE_STORAGE_CONTAINER: string;
  TENSORLAKE_API_KEY: string;
  LOG_ENABLED?: string;
  SEARCH_CACHE: KVNamespace;
  TAGS_CACHE: KVNamespace;
}

export type UploadStep = 
  | 'init'
  | 'blob_upload'
  | 'tensorlake_parse'
  | 'tensorlake_poll'
  | 'html_cleanup'
  | 'title_gen'
  | 'chunking'
  | 'embedding'
  | 'db_insert'
  | 'vectorize_upsert'
  | 'finalize'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface UploadState {
  // Identity
  trace_id: string;
  user_id: string;
  upload_type: 'file' | 'screenshot' | 'quick_note';
  
  // Input data
  original_filename?: string;
  file_type?: string;
  file_size_bytes?: number;
  tag?: string;
  auth_method?: string;
  
  // Pipeline state
  current_step: UploadStep;
  cancelled: boolean;
  
  // Intermediate results (persisted for resume)
  blob_url?: string;
  blob_name?: string;
  sas_url?: string;
  tensorlake_parse_id?: string;
  tensorlake_poll_attempts?: number;
  content?: string;
  content_length?: number;
  conversion_method?: string;
  title?: string;
  chunks?: string[];
  embeddings?: number[][];
  note_id?: string;
  vector_count?: number;
  
  // Timestamps
  request_received_at: string;
  processing_started_at?: string;
  blob_upload_started_at?: string;
  blob_upload_completed_at?: string;
  conversion_started_at?: string;
  conversion_completed_at?: string;
  html_cleanup_started_at?: string;
  html_cleanup_completed_at?: string;
  title_gen_started_at?: string;
  title_gen_completed_at?: string;
  embedding_started_at?: string;
  embedding_completed_at?: string;
  db_insert_started_at?: string;
  db_insert_completed_at?: string;
  vectorize_started_at?: string;
  vectorize_completed_at?: string;
  completed_at?: string;
  
  // Timing (ms)
  timing_blob_upload_ms?: number;
  timing_conversion_ms?: number;
  timing_html_cleanup_ms?: number;
  timing_title_gen_ms?: number;
  timing_embedding_ms?: number;
  timing_db_insert_ms?: number;
  timing_vectorize_ms?: number;
  timing_total_ms?: number;
  
  // Quota
  user_storage_before_bytes?: number;
  user_storage_after_bytes?: number;
  
  // Errors
  error_message?: string;
  pipeline_errors?: string[];
  step_errors?: Record<string, string>;  // Per-step error details
}

// Constants
const MAX_CHUNK_WORDS = 400;
const MIN_CHUNK_WORDS = 100;
const FALLBACK_CHUNK_SIZE = 500;
const FALLBACK_OVERLAP = 50;

const PLAIN_TEXT_EXTENSIONS = new Set([
  '.txt', '.md', '.markdown', '.csv', '.json', '.xml', '.yaml', '.yml',
  '.log', '.ini', '.cfg', '.conf', '.py', '.js', '.ts', '.html', '.css',
  '.sql', '.sh', '.bat', '.ps1', '.env', '.gitignore', '.dockerignore',
]);

const TENSORLAKE_BASE = 'https://api.tensorlake.ai/documents/v2';

// ============================================================================
// Upload Processor Durable Object
// ============================================================================

export class UploadProcessor extends DurableObject<UploadProcessorEnv> {
  private state!: UploadState;
  private fileData: ArrayBuffer | null = null;
  private startTime: number = 0;
  
  constructor(ctx: DurableObjectState, env: UploadProcessorEnv) {
    super(ctx, env);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // HTTP Fetch Handler
  // ─────────────────────────────────────────────────────────────────────────
  
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    
    // POST /start - Start processing an upload
    if (path === '/start' && request.method === 'POST') {
      return this.handleStart(request);
    }
    
    // POST /cancel - Cancel the upload
    if (path === '/cancel' && request.method === 'POST') {
      return this.handleCancel();
    }
    
    // GET /status - Get current status
    if (path === '/status' && request.method === 'GET') {
      return this.handleStatus();
    }
    
    return new Response('Not found', { status: 404 });
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Start Upload Processing
  // ─────────────────────────────────────────────────────────────────────────
  
  private async handleStart(request: Request): Promise<Response> {
    try {
      const body = await request.json() as {
        trace_id: string;
        user_id: string;
        upload_type: 'file' | 'screenshot' | 'quick_note';
        original_filename?: string;
        file_type?: string;
        file_size_bytes?: number;
        tag?: string;
        auth_method?: string;
        user_storage_before_bytes?: number;
        // File data as base64 for files/screenshots
        file_data_base64?: string;
        // Direct markdown for quick notes
        markdown_content?: string;
      };
      
      this.startTime = Date.now();
      
      // Initialize state
      this.state = {
        trace_id: body.trace_id,
        user_id: body.user_id,
        upload_type: body.upload_type,
        original_filename: body.original_filename,
        file_type: body.file_type,
        file_size_bytes: body.file_size_bytes,
        tag: body.tag,
        auth_method: body.auth_method,
        current_step: 'init',
        cancelled: false,
        request_received_at: new Date().toISOString(),
        user_storage_before_bytes: body.user_storage_before_bytes,
        pipeline_errors: [],
        step_errors: {},
      };
      
      // Store file data
      if (body.file_data_base64) {
        this.fileData = this.base64ToArrayBuffer(body.file_data_base64);
      } else if (body.markdown_content) {
        // Quick note - content is already markdown
        this.state.content = body.markdown_content;
        this.state.conversion_method = 'direct';
      }
      
      // Save initial state
      await this.saveState();
      
      // Insert trace into Supabase
      await this.insertUploadTrace();
      
      // Start processing (non-blocking via alarm)
      await this.ctx.storage.setAlarm(Date.now() + 10);
      
      return new Response(JSON.stringify({
        success: true,
        trace_id: this.state.trace_id,
        message: 'Upload processing started',
      }), {
        status: 202,
        headers: { 'Content-Type': 'application/json' },
      });
    } catch (err) {
      console.error('[UploadProcessor] Start error:', err);
      return new Response(JSON.stringify({ error: String(err) }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Cancel Upload
  // ─────────────────────────────────────────────────────────────────────────
  
  private async handleCancel(): Promise<Response> {
    // Load state if not loaded
    if (!this.state) {
      await this.loadState();
    }
    
    if (!this.state) {
      return new Response(JSON.stringify({ error: 'No upload found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    // Already completed or failed
    if (this.state.current_step === 'completed' || this.state.current_step === 'failed') {
      return new Response(JSON.stringify({
        error: 'Upload already finished',
        status: this.state.current_step,
      }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    // Mark as cancelled
    this.state.cancelled = true;
    this.state.current_step = 'cancelled';
    this.state.completed_at = new Date().toISOString();
    this.state.timing_total_ms = Date.now() - new Date(this.state.request_received_at).getTime();
    
    await this.saveState();
    await this.updateUploadTrace({
      status: 'cancelled',
      completed_at: this.state.completed_at,
      timing_total_ms: this.state.timing_total_ms,
      error_message: 'Cancelled by user',
    });
    
    // Delete any pending alarms
    await this.ctx.storage.deleteAlarm();
    
    console.log(`[UploadProcessor] Cancelled: ${this.state.trace_id}`);
    
    return new Response(JSON.stringify({
      success: true,
      trace_id: this.state.trace_id,
      message: 'Upload cancelled',
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Get Status
  // ─────────────────────────────────────────────────────────────────────────
  
  private async handleStatus(): Promise<Response> {
    // Load state if not loaded
    if (!this.state) {
      await this.loadState();
    }
    
    if (!this.state) {
      return new Response(JSON.stringify({ error: 'No upload found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    return new Response(JSON.stringify({
      trace_id: this.state.trace_id,
      status: this.state.cancelled ? 'cancelled' : this.state.current_step,
      upload_type: this.state.upload_type,
      original_filename: this.state.original_filename,
      title: this.state.title,
      note_id: this.state.note_id,
      error_message: this.state.error_message,
      tensorlake_poll_attempts: this.state.tensorlake_poll_attempts,
      timing_total_ms: this.state.timing_total_ms,
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Alarm Handler - Main Processing Loop
  // ─────────────────────────────────────────────────────────────────────────
  
  async alarm(): Promise<void> {
    // Load state
    await this.loadState();
    
    if (!this.state) {
      console.error('[UploadProcessor] Alarm fired but no state found');
      return;
    }
    
    // Check if cancelled
    if (this.state.cancelled) {
      console.log(`[UploadProcessor] Skipping alarm - upload cancelled: ${this.state.trace_id}`);
      return;
    }
    
    // Check if already done
    if (this.state.current_step === 'completed' || this.state.current_step === 'failed') {
      console.log(`[UploadProcessor] Skipping alarm - upload ${this.state.current_step}: ${this.state.trace_id}`);
      return;
    }
    
    console.log(`[UploadProcessor] Processing step: ${this.state.current_step} for ${this.state.trace_id}`);
    
    try {
      await this.processNextStep();
    } catch (err) {
      const failedStep = this.state.current_step;
      console.error(`[UploadProcessor] Error in step ${failedStep}:`, err);
      
      // Record the error for this specific step
      this.state.error_message = String(err);
      if (!this.state.step_errors) this.state.step_errors = {};
      this.state.step_errors[failedStep] = String(err);
      
      this.state.current_step = 'failed';
      this.state.completed_at = new Date().toISOString();
      this.state.timing_total_ms = Date.now() - new Date(this.state.request_received_at).getTime();
      await this.saveState();
      await this.updateUploadTrace({
        status: 'failed',
        error_message: this.state.error_message,
        completed_at: this.state.completed_at,
        timing_total_ms: this.state.timing_total_ms,
        pipeline_errors: this.state.pipeline_errors,
        step_errors: this.state.step_errors,
      });
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step Processing
  // ─────────────────────────────────────────────────────────────────────────
  
  private async processNextStep(): Promise<void> {
    switch (this.state.current_step) {
      case 'init':
        await this.stepBlobUpload();
        break;
      case 'blob_upload':
        await this.stepTensorLakeParse();
        break;
      case 'tensorlake_parse':
        await this.stepTensorLakePoll();
        break;
      case 'tensorlake_poll':
        // Poll continues until done or cancelled
        await this.stepTensorLakePoll();
        break;
      case 'html_cleanup':
        await this.stepHtmlCleanup();
        break;
      case 'title_gen':
        await this.stepTitleGen();
        break;
      case 'chunking':
        await this.stepChunking();
        break;
      case 'embedding':
        await this.stepEmbedding();
        break;
      case 'db_insert':
        await this.stepDbInsert();
        break;
      case 'vectorize_upsert':
        await this.stepVectorizeUpsert();
        break;
      case 'finalize':
        await this.stepFinalize();
        break;
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 1: Blob Upload
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepBlobUpload(): Promise<void> {
    this.state.processing_started_at = new Date().toISOString();
    
    // Update trace to processing
    await this.updateUploadTrace({
      status: 'processing',
      processing_started_at: this.state.processing_started_at,
    });
    
    // Quick notes skip blob upload
    if (this.state.upload_type === 'quick_note' || !this.fileData) {
      this.state.current_step = 'html_cleanup';
      await this.saveState();
      await this.scheduleNextStep(10);
      return;
    }
    
    this.state.blob_upload_started_at = new Date().toISOString();
    const blobStart = Date.now();
    
    try {
      const result = await this.uploadToAzureBlob();
      this.state.blob_url = result.blobUrl;
      this.state.blob_name = result.blobName;
      this.state.timing_blob_upload_ms = Date.now() - blobStart;
      this.state.blob_upload_completed_at = new Date().toISOString();
      
      console.log(`[UploadProcessor] Blob uploaded: ${result.blobName} (${this.state.timing_blob_upload_ms}ms)`);
      
      // Update trace
      await this.updateUploadTrace({
        blob_url: this.state.blob_url,
        blob_upload_started_at: this.state.blob_upload_started_at,
        blob_upload_completed_at: this.state.blob_upload_completed_at,
        timing_blob_upload_ms: this.state.timing_blob_upload_ms,
      });
      
      // Move to next step
      this.state.current_step = 'blob_upload';
      await this.saveState();
      await this.scheduleNextStep(10);
    } catch (err) {
      this.state.pipeline_errors!.push(`Blob upload: ${err}`);
      throw err;
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 2: TensorLake Parse Start
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepTensorLakeParse(): Promise<void> {
    const filename = this.state.original_filename || 'document';
    const fileExt = '.' + (filename.split('.').pop()?.toLowerCase() || '');
    const isPlainText = PLAIN_TEXT_EXTENSIONS.has(fileExt);
    
    // Plain text - read directly
    if (isPlainText && this.fileData) {
      this.state.conversion_started_at = new Date().toISOString();
      const convStart = Date.now();
      try {
        this.state.content = new TextDecoder().decode(this.fileData);
        this.state.conversion_method = 'plain_text';
      } catch (err) {
        this.state.pipeline_errors!.push(`Text decode: ${err}`);
        throw err;
      }
      this.state.timing_conversion_ms = Date.now() - convStart;
      this.state.conversion_completed_at = new Date().toISOString();
      this.state.content_length = this.state.content.length;
      
      await this.updateUploadTrace({
        conversion_method: 'plain_text',
        conversion_started_at: this.state.conversion_started_at,
        conversion_completed_at: this.state.conversion_completed_at,
        timing_conversion_ms: this.state.timing_conversion_ms,
        content_length: this.state.content_length,
      });
      
      // Skip to HTML cleanup
      this.state.current_step = 'html_cleanup';
      await this.saveState();
      await this.scheduleNextStep(10);
      return;
    }
    
    // No blob URL - can't use TensorLake
    if (!this.state.blob_url) {
      throw new Error('No blob URL available for TensorLake conversion');
    }
    
    // Generate SAS URL
    this.state.sas_url = await this.generateBlobSasUrl(this.state.blob_url);
    
    // Start TensorLake parse
    this.state.conversion_started_at = new Date().toISOString();
    
    await this.updateUploadTrace({
      conversion_started_at: this.state.conversion_started_at,
    });
    
    const parseResp = await fetch(`${TENSORLAKE_BASE}/read`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.env.TENSORLAKE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ file_url: this.state.sas_url }),
    });
    
    if (!parseResp.ok) {
      const errText = await parseResp.text();
      throw new Error(`TensorLake parse start failed: ${parseResp.status} - ${errText.substring(0, 200)}`);
    }
    
    const parseData: any = await parseResp.json();
    this.state.tensorlake_parse_id = parseData.parse_id || parseData.task_id;
    
    if (!this.state.tensorlake_parse_id) {
      throw new Error('TensorLake did not return a parse_id');
    }
    
    console.log(`[UploadProcessor] TensorLake parse started: ${this.state.tensorlake_parse_id}`);
    
    this.state.tensorlake_poll_attempts = 0;
    this.state.current_step = 'tensorlake_poll';
    await this.saveState();
    
    // Start polling with alarm
    await this.scheduleNextStep(500);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 3: TensorLake Poll (via alarms - no timeout!)
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepTensorLakePoll(): Promise<void> {
    if (!this.state.tensorlake_parse_id) {
      throw new Error('No TensorLake parse_id to poll');
    }
    
    this.state.tensorlake_poll_attempts = (this.state.tensorlake_poll_attempts || 0) + 1;
    
    const pollResp = await fetch(`${TENSORLAKE_BASE}/parse/${this.state.tensorlake_parse_id}`, {
      headers: { 'Authorization': `Bearer ${this.env.TENSORLAKE_API_KEY}` },
    });
    
    if (!pollResp.ok) {
      const errText = await pollResp.text();
      throw new Error(`TensorLake poll failed: ${pollResp.status} - ${errText.substring(0, 200)}`);
    }
    
    const pollData: any = await pollResp.json();
    const status = (pollData.status || '').toLowerCase();
    
    // Log progress
    if (this.state.tensorlake_poll_attempts! % 10 === 0) {
      console.log(`[UploadProcessor] TensorLake poll ${this.state.tensorlake_poll_attempts}: status="${status}"`);
    }
    
    // Still processing - schedule another poll
    if (status === 'processing' || status === 'pending' || status === 'queued') {
      await this.saveState();
      // Adaptive delay: fast initially, slower over time
      const delay = this.getPollingDelay(this.state.tensorlake_poll_attempts!);
      await this.scheduleNextStep(delay);
      return;
    }
    
    // Success!
    if (status === 'successful' || status === 'completed' || status === 'success' || pollData.result) {
      const content = this.extractTensorLakeContent(pollData);
      
      if (!content) {
        throw new Error('TensorLake returned empty content');
      }
      
      this.state.content = content;
      this.state.content_length = content.length;
      this.state.conversion_method = 'tensorlake';
      this.state.conversion_completed_at = new Date().toISOString();
      this.state.timing_conversion_ms = new Date(this.state.conversion_completed_at).getTime() - 
                                        new Date(this.state.conversion_started_at!).getTime();
      
      console.log(`[UploadProcessor] TensorLake done: ${content.length} chars after ${this.state.tensorlake_poll_attempts} polls`);
      
      await this.updateUploadTrace({
        conversion_method: 'tensorlake',
        conversion_completed_at: this.state.conversion_completed_at,
        timing_conversion_ms: this.state.timing_conversion_ms,
        content_length: this.state.content_length,
      });
      
      // Move to HTML cleanup
      this.state.current_step = 'html_cleanup';
      await this.saveState();
      await this.scheduleNextStep(10);
      return;
    }
    
    // Failed
    if (status === 'failed' || pollData.error) {
      throw new Error(`TensorLake conversion failed: ${pollData.error || 'Unknown error'}`);
    }
    
    // Unknown status - keep polling (might be a transient state)
    await this.saveState();
    await this.scheduleNextStep(2000);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 4: HTML Cleanup
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepHtmlCleanup(): Promise<void> {
    if (!this.state.content) {
      throw new Error('No content to process');
    }
    
    // Check if HTML cleanup is needed
    if (this.needsHtmlCleanup(this.state.content)) {
      this.state.html_cleanup_started_at = new Date().toISOString();
      const cleanStart = Date.now();
      
      try {
        this.state.content = await this.cleanHtmlWithLlm(this.state.content);
        console.log(`[UploadProcessor] HTML cleanup done: ${this.state.content.length} chars`);
      } catch (err) {
        this.state.pipeline_errors!.push(`HTML cleanup: ${err}`);
        console.error('[UploadProcessor] HTML cleanup failed, using raw content:', err);
      }
      
      this.state.timing_html_cleanup_ms = Date.now() - cleanStart;
      this.state.html_cleanup_completed_at = new Date().toISOString();
      
      await this.updateUploadTrace({
        html_cleanup_started_at: this.state.html_cleanup_started_at,
        html_cleanup_completed_at: this.state.html_cleanup_completed_at,
        timing_html_cleanup_ms: this.state.timing_html_cleanup_ms,
      });
    }
    
    this.state.current_step = 'title_gen';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 5: Title Generation
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepTitleGen(): Promise<void> {
    this.state.title_gen_started_at = new Date().toISOString();
    const titleStart = Date.now();
    
    try {
      this.state.title = await this.generateTitleWithLlm(
        this.state.content!,
        this.state.original_filename
      );
      console.log(`[UploadProcessor] Title: ${this.state.title.substring(0, 80)}...`);
    } catch (err) {
      this.state.pipeline_errors!.push(`Title generation: ${err}`);
      this.state.title = this.state.original_filename || 'Untitled Document';
      console.error('[UploadProcessor] Title generation failed, using filename:', err);
    }
    
    this.state.timing_title_gen_ms = Date.now() - titleStart;
    this.state.title_gen_completed_at = new Date().toISOString();
    
    await this.updateUploadTrace({
      title_gen_started_at: this.state.title_gen_started_at,
      title_gen_completed_at: this.state.title_gen_completed_at,
      timing_title_gen_ms: this.state.timing_title_gen_ms,
      title_generated: this.state.title,
    });
    
    this.state.current_step = 'chunking';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 6: Chunking
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepChunking(): Promise<void> {
    this.state.chunks = this.chunkText(this.state.content!);
    console.log(`[UploadProcessor] Chunked into ${this.state.chunks.length} chunks`);
    
    await this.updateUploadTrace({
      chunk_count: this.state.chunks.length,
    });
    
    this.state.current_step = 'embedding';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 7: Embedding Generation
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepEmbedding(): Promise<void> {
    this.state.embedding_started_at = new Date().toISOString();
    const embedStart = Date.now();
    
    try {
      // Generate embeddings for document summary + all chunks
      const docSummary = this.state.content!.split(/\s+/).slice(0, 1000).join(' ');
      const textsToEmbed = [docSummary, ...this.state.chunks!];
      
      const response = await this.env.AI.run(this.env.EMBEDDING_MODEL as any, {
        text: textsToEmbed,
      });
      
      this.state.embeddings = (response as any).data;
      console.log(`[UploadProcessor] Generated ${this.state.embeddings!.length} embeddings`);
    } catch (err) {
      throw new Error(`Embedding generation failed: ${err}`);
    }
    
    this.state.timing_embedding_ms = Date.now() - embedStart;
    this.state.embedding_completed_at = new Date().toISOString();
    
    await this.updateUploadTrace({
      embedding_started_at: this.state.embedding_started_at,
      embedding_completed_at: this.state.embedding_completed_at,
      timing_embedding_ms: this.state.timing_embedding_ms,
    });
    
    this.state.current_step = 'db_insert';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 8: Supabase DB Insert
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepDbInsert(): Promise<void> {
    this.state.db_insert_started_at = new Date().toISOString();
    
    await this.updateUploadTrace({
      db_insert_started_at: this.state.db_insert_started_at,
    });
    
    const dbStart = Date.now();
    
    try {
      const fileType = this.state.upload_type === 'screenshot' ? 'screenshot'
        : this.state.upload_type === 'quick_note' ? 'quick_note'
        : 'uploaded_file';
      
      const noteData = {
        user_id: this.state.user_id,
        title: this.state.title,
        content_markdown: this.state.content,
        tag: this.state.tag || 'General',
        file_type: fileType,
        original_filename: this.state.original_filename,
        blob_url: this.state.blob_url,
        embedding: `[${this.state.embeddings![0].join(',')}]`,
        status: 'incomplete',  // Will be set to 'active' in finalize step
        metadata: {
          blob_name: this.state.blob_name,
          size_bytes: this.state.file_size_bytes || this.state.content!.length,
          chunk_count: this.state.chunks!.length,
          conversion_method: this.state.conversion_method || 'direct',
          upload_source: 'worker_do',
        },
      };
      
      const insertResp = await fetch(`${this.env.SUPABASE_URL}/rest/v1/notes`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': this.env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${this.env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=representation',
        },
        body: JSON.stringify(noteData),
      });
      
      if (!insertResp.ok) {
        const errText = await insertResp.text();
        throw new Error(`Supabase insert failed: ${insertResp.status} - ${errText}`);
      }
      
      const inserted = await insertResp.json() as Array<{ id: string }>;
      this.state.note_id = inserted[0].id;
      console.log(`[UploadProcessor] Note inserted: ${this.state.note_id}`);
    } catch (err) {
      throw new Error(`Database insert failed: ${err}`);
    }
    
    this.state.timing_db_insert_ms = Date.now() - dbStart;
    this.state.db_insert_completed_at = new Date().toISOString();
    
    this.state.current_step = 'vectorize_upsert';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 9: Vectorize Upsert
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepVectorizeUpsert(): Promise<void> {
    this.state.vectorize_started_at = new Date().toISOString();
    const vecStart = Date.now();
    
    try {
      const vectors: VectorizeVector[] = [];
      
      // Document-level vector
      vectors.push({
        id: `${this.state.note_id}_doc`,
        values: this.state.embeddings![0],
        metadata: {
          note_id: this.state.note_id,
          user_id: this.state.user_id,
          title: this.state.title!.substring(0, 200),
          tag: this.state.tag || 'General',
          chunk_type: 'document',
          chunk_index: 0,
        } as Record<string, VectorizeVectorMetadata>,
      });
      
      // Chunk vectors
      for (let i = 0; i < this.state.chunks!.length; i++) {
        vectors.push({
          id: `${this.state.note_id}_chunk_${i}`,
          values: this.state.embeddings![i + 1],
          metadata: {
            note_id: this.state.note_id,
            user_id: this.state.user_id,
            title: this.state.title!.substring(0, 200),
            tag: this.state.tag || 'General',
            chunk_type: 'chunk',
            chunk_index: i,
            chunk_text: this.state.chunks![i].substring(0, 500),
          } as Record<string, VectorizeVectorMetadata>,
        });
      }
      
      // Batch upsert
      for (let i = 0; i < vectors.length; i += 1000) {
        const batch = vectors.slice(i, i + 1000);
        await this.env.VECTORIZE.upsert(batch);
      }
      
      this.state.vector_count = vectors.length;
      console.log(`[UploadProcessor] Upserted ${vectors.length} vectors`);
    } catch (err) {
      this.state.pipeline_errors!.push(`Vectorize upsert: ${err}`);
      console.error('[UploadProcessor] Vectorize upsert failed:', err);
      // Don't throw - note is already in DB
    }
    
    this.state.timing_vectorize_ms = Date.now() - vecStart;
    this.state.vectorize_completed_at = new Date().toISOString();
    
    this.state.current_step = 'finalize';
    await this.saveState();
    await this.scheduleNextStep(10);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Step 10: Finalize
  // ─────────────────────────────────────────────────────────────────────────
  
  private async stepFinalize(): Promise<void> {
    // Mark note as active (searchable) now that pipeline is complete
    try {
      const updateResp = await fetch(
        `${this.env.SUPABASE_URL}/rest/v1/notes?id=eq.${this.state.note_id}`,
        {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'apikey': this.env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${this.env.SUPABASE_SERVICE_KEY}`,
          },
          body: JSON.stringify({ status: 'active' }),
        }
      );
      if (!updateResp.ok) {
        console.error('[UploadProcessor] Failed to set note status to active:', await updateResp.text());
      } else {
        console.log(`[UploadProcessor] Note ${this.state.note_id} marked as active`);
      }
    } catch (err) {
      this.state.pipeline_errors!.push(`Note status update: ${err}`);
    }
    
    // Cache invalidation
    try {
      await this.env.SEARCH_CACHE.put(`version_${this.state.user_id}`, Date.now().toString());
      await this.env.TAGS_CACHE.delete(`tags_${this.state.user_id}`);
      console.log(`[UploadProcessor] Invalidated caches for user ${this.state.user_id.substring(0, 8)}`);
    } catch (err) {
      this.state.pipeline_errors!.push(`Cache invalidation: ${err}`);
    }
    
    // Check storage quota after
    try {
      const quotaAfter = await this.checkStorageQuota(this.state.user_id);
      this.state.user_storage_after_bytes = quotaAfter.totalBytes;
    } catch (err) {
      console.error('[UploadProcessor] Failed to get post-upload quota:', err);
    }
    
    // Mark complete
    this.state.current_step = 'completed';
    this.state.completed_at = new Date().toISOString();
    this.state.timing_total_ms = new Date(this.state.completed_at).getTime() - 
                                 new Date(this.state.request_received_at).getTime();
    
    console.log(`[UploadProcessor] ✅ Complete: ${this.state.trace_id} in ${this.state.timing_total_ms}ms`);
    
    // Final trace update
    await this.updateUploadTrace({
      status: 'completed',
      db_insert_completed_at: this.state.db_insert_completed_at,
      vectorize_started_at: this.state.vectorize_started_at,
      vectorize_completed_at: this.state.vectorize_completed_at,
      completed_at: this.state.completed_at,
      timing_db_insert_ms: this.state.timing_db_insert_ms,
      timing_vectorize_ms: this.state.timing_vectorize_ms,
      timing_total_ms: this.state.timing_total_ms,
      note_id: this.state.note_id,
      vector_count: this.state.vector_count,
      user_storage_after_bytes: this.state.user_storage_after_bytes,
      pipeline_errors: this.state.pipeline_errors?.length ? this.state.pipeline_errors : undefined,
    });
    
    await this.saveState();
    
    // Clean up: clear file data from memory (already processed)
    this.fileData = null;
    
    // Clear embeddings and chunks from storage (large data, not needed anymore)
    this.state.embeddings = undefined;
    this.state.chunks = undefined;
    this.state.content = undefined;
    await this.saveState();
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Schedule Next Step
  // ─────────────────────────────────────────────────────────────────────────
  
  private async scheduleNextStep(delayMs: number): Promise<void> {
    await this.ctx.storage.setAlarm(Date.now() + delayMs);
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Get Polling Delay
  // ─────────────────────────────────────────────────────────────────────────
  
  private getPollingDelay(attempt: number): number {
    if (attempt < 3) return 100;
    if (attempt < 8) return 300;
    if (attempt < 15) return 500;
    if (attempt < 40) return 1000;
    if (attempt < 80) return 2000;
    return 5000;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: State Persistence
  // ─────────────────────────────────────────────────────────────────────────
  
  private async saveState(): Promise<void> {
    await this.ctx.storage.put('state', this.state);
    // Store file data separately if exists
    if (this.fileData) {
      await this.ctx.storage.put('fileData', this.fileData);
    }
  }
  
  private async loadState(): Promise<void> {
    const stored = await this.ctx.storage.get<UploadState>('state');
    if (stored) {
      this.state = stored;
    }
    // Load file data if we need it (before TensorLake step)
    if (!this.fileData && this.state && ['init', 'blob_upload', 'tensorlake_parse'].includes(this.state.current_step)) {
      this.fileData = await this.ctx.storage.get<ArrayBuffer>('fileData') || null;
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Base64 Conversion
  // ─────────────────────────────────────────────────────────────────────────
  
  private base64ToArrayBuffer(base64: string): ArrayBuffer {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Azure Blob Upload
  // ─────────────────────────────────────────────────────────────────────────
  
  private async uploadToAzureBlob(): Promise<{ blobUrl: string; blobName: string }> {
    const { accountName, accountKey } = this.parseConnectionString(
      this.env.AZURE_STORAGE_CONNECTION_STRING
    );
    const container = this.env.AZURE_STORAGE_CONTAINER;
    const filename = this.state.original_filename || 'document';
    
    const ext = filename.includes('.') ? filename.split('.').pop() : 'bin';
    const timestamp = Date.now();
    const uuid = crypto.randomUUID();
    const blobName = `${this.state.user_id}/${this.state.upload_type}/${timestamp}_${uuid}.${ext}`;
    
    const url = `https://${accountName}.blob.core.windows.net/${container}/${blobName}`;
    const xmsDate = new Date().toUTCString();
    const xmsVersion = '2020-10-02';
    
    const contentType = this.getMimeType(filename);
    
    const headers: Record<string, string> = {
      'Content-Type': contentType,
      'x-ms-blob-type': 'BlockBlob',
      'x-ms-date': xmsDate,
      'x-ms-version': xmsVersion,
    };
    
    const authHeader = await this.createSharedKeyAuth(
      accountName, accountKey, 'PUT', url, headers, this.fileData!.byteLength
    );
    
    const response = await fetch(url, {
      method: 'PUT',
      headers: {
        ...headers,
        'Authorization': authHeader,
        'Content-Length': this.fileData!.byteLength.toString(),
      },
      body: this.fileData,
    });
    
    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Azure Blob upload failed: ${response.status} - ${errorText}`);
    }
    
    return { blobUrl: url, blobName };
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Generate SAS URL
  // ─────────────────────────────────────────────────────────────────────────
  
  private async generateBlobSasUrl(blobUrl: string, expiryMinutes: number = 60): Promise<string> {
    const { accountName, accountKey } = this.parseConnectionString(
      this.env.AZURE_STORAGE_CONNECTION_STRING
    );
    
    const urlObj = new URL(blobUrl);
    const pathParts = urlObj.pathname.split('/').filter(Boolean);
    const container = pathParts[0];
    const blobName = pathParts.slice(1).join('/');
    
    const version = '2020-10-02';
    const now = new Date();
    const start = new Date(now.getTime() - 5 * 60 * 1000);
    const expiry = new Date(now.getTime() + expiryMinutes * 60 * 1000);
    
    const sp = 'r';           // permissions: read
    const sr = 'b';           // signed resource: blob
    const st = start.toISOString().replace(/\.\d{3}Z$/, 'Z');
    const se = expiry.toISOString().replace(/\.\d{3}Z$/, 'Z');
    const spr = 'https';
    
    // String to sign for Service SAS (15 components)
    const stringToSign = [
      sp,                                          // signedPermissions
      st,                                          // signedStart
      se,                                          // signedExpiry
      `/blob/${accountName}/${container}/${blobName}`, // canonicalizedResource
      '',                                          // signedIdentifier
      '',                                          // signedIP
      spr,                                         // signedProtocol
      version,                                     // signedVersion
      sr,                                          // signedResource
      '',                                          // signedSnapshotTime
      '',                                          // rscc (cache-control)
      '',                                          // rscd (content-disposition)
      '',                                          // rsce (content-encoding)
      '',                                          // rscl (content-language)
      '',                                          // rsct (content-type)
    ].join('\n');
    
    const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    );
    const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
    const sig = btoa(String.fromCharCode(...new Uint8Array(signature)));
    
    const params = new URLSearchParams({ sv: version, st, se, sr, sp, spr, sig });
    return `${blobUrl}?${params.toString()}`;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Parse Azure Connection String
  // ─────────────────────────────────────────────────────────────────────────
  
  private parseConnectionString(connStr: string): { accountName: string; accountKey: string } {
    const parts = connStr.split(';');
    let accountName = '';
    let accountKey = '';
    for (const part of parts) {
      if (part.startsWith('AccountName=')) accountName = part.substring(12);
      if (part.startsWith('AccountKey=')) accountKey = part.substring(11);
    }
    return { accountName, accountKey };
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Create Shared Key Auth
  // ─────────────────────────────────────────────────────────────────────────
  
  private async createSharedKeyAuth(
    accountName: string,
    accountKey: string,
    method: string,
    url: string,
    headers: Record<string, string>,
    contentLength: number
  ): Promise<string> {
    const xmsHeaders = Object.entries(headers)
      .filter(([k]) => k.toLowerCase().startsWith('x-ms-'))
      .sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase()))
      .map(([k, v]) => `${k.toLowerCase()}:${v}`)
      .join('\n');
    
    const urlObj = new URL(url);
    const canonicalResource = `/${accountName}${urlObj.pathname}`;
    
    const contentType = headers['Content-Type'] || '';
    const stringToSign = [
      method, '', '', contentLength.toString(), '', contentType,
      '', '', '', '', '', '', xmsHeaders, canonicalResource,
    ].join('\n');
    
    const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    );
    const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
    const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)));
    
    return `SharedKey ${accountName}:${signatureB64}`;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Get MIME Type
  // ─────────────────────────────────────────────────────────────────────────
  
  private getMimeType(filename: string): string {
    const ext = filename.toLowerCase().split('.').pop() || '';
    const mimeMap: Record<string, string> = {
      pdf: 'application/pdf', doc: 'application/msword',
      docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      xls: 'application/vnd.ms-excel',
      xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ppt: 'application/vnd.ms-powerpoint',
      pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
      webp: 'image/webp', bmp: 'image/bmp', tiff: 'image/tiff',
      html: 'text/html', txt: 'text/plain', csv: 'text/csv',
      json: 'application/json', xml: 'application/xml',
    };
    return mimeMap[ext] || 'application/octet-stream';
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Extract TensorLake Content
  // ─────────────────────────────────────────────────────────────────────────
  
  private extractTensorLakeContent(pollData: any): string | null {
    // Prefer document_markdown
    const docMarkdown = pollData?.document_markdown || pollData?.result?.document_markdown;
    if (docMarkdown && docMarkdown.trim()) return docMarkdown;
    
    // Try chunks
    const chunks = pollData?.chunks || pollData?.result?.chunks || [];
    if (chunks.length > 0) {
      const content = chunks.map((c: any) => c.content || c.text || '').join('\n\n');
      if (content.trim()) return content;
    }
    
    // Try pages
    const pages = pollData?.pages || pollData?.result?.pages || [];
    if (pages.length > 0) {
      const pageTexts: string[] = [];
      for (const page of pages) {
        if (page.page_fragments) {
          for (const frag of page.page_fragments) {
            const text = frag?.content?.content || frag?.content || frag?.text || '';
            if (text) pageTexts.push(text);
          }
        } else {
          const text = page.content || page.text || '';
          if (text) pageTexts.push(text);
        }
      }
      if (pageTexts.length > 0) return pageTexts.join('\n\n');
    }
    
    // Try markdown
    const md = pollData?.markdown || pollData?.result?.markdown;
    if (md) return md;
    
    return null;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: HTML Cleanup Detection
  // ─────────────────────────────────────────────────────────────────────────
  
  private needsHtmlCleanup(content: string): boolean {
    const htmlTagCount = (content.match(/<[a-z][\s\S]*?>/gi) || []).length;
    const hasStructuralTags = /<(table|thead|tbody|tr|td|th|div|span|section|article|nav|header|footer)\b/i.test(content);
    return hasStructuralTags || htmlTagCount > 10;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: HTML Cleanup with LLM
  // ─────────────────────────────────────────────────────────────────────────
  
  private async cleanHtmlWithLlm(html: string): Promise<string> {
    const truncated = html.substring(0, 30000);
    
    const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.env.GROQ_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'llama-3.3-70b-versatile',
        messages: [
          {
            role: 'system',
            content: `Convert HTML to clean markdown for semantic search.

Rules:
1. Convert HTML tables to markdown tables or readable list format
2. Preserve ALL information - do NOT summarize
3. Remove all HTML tags - output pure markdown/text
4. Remove empty paragraphs and excessive whitespace
5. Keep headings, lists, contact info, skills, dates, names

Output ONLY the converted markdown.`,
          },
          { role: 'user', content: truncated },
        ],
        temperature: 0,
        max_tokens: 8000,
      }),
    });
    
    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Groq HTML cleanup failed: ${response.status} - ${errText}`);
    }
    
    const result = await response.json() as any;
    return result.choices?.[0]?.message?.content || html;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Title Generation with LLM
  // ─────────────────────────────────────────────────────────────────────────
  
  private async generateTitleWithLlm(content: string, filename?: string): Promise<string> {
    const contentPreview = content.substring(0, 4000);
    const filenameHint = filename ? `\nOriginal filename: ${filename}` : '';
    
    const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.env.GROQ_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'llama-3.3-70b-versatile',
        messages: [
          {
            role: 'system',
            content: 'You are a document analysis expert. Generate concise, descriptive titles.',
          },
          {
            role: 'user',
            content: `Analyze this document and generate a descriptive title/summary that captures what it contains. This will be used for document retrieval and search.
${filenameHint}
Document content:
---
${contentPreview}
---

Requirements for the title:
1. Start with the document type and main subject (e.g., "Resume of Amit Navgire - ...")
2. Include the person's name if identifiable
3. Summarize key topics: roles, skills, companies, expertise areas, or main themes
4. Be specific enough that someone searching could find this document
5. Length: 150-250 characters (detailed but concise)
6. Do NOT include quotes around the title
7. Use natural language, not bullet points

Generate ONLY the title, nothing else:`,
          },
        ],
        temperature: 0.3,
        max_tokens: 100,
      }),
    });
    
    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Groq title gen failed: ${response.status} - ${errText}`);
    }
    
    const result = await response.json() as any;
    let title = result.choices?.[0]?.message?.content?.trim() || '';
    title = title.replace(/^["']|["']$/g, '').substring(0, 300);
    return title || filename || 'Untitled Document';
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Text Chunking
  // ─────────────────────────────────────────────────────────────────────────
  
  private chunkText(text: string): string[] {
    const trimmed = text.trim();
    if (!trimmed) return [];
    
    const words = trimmed.split(/\s+/).filter(w => w.length > 0);
    if (words.length <= MIN_CHUNK_WORDS) return [trimmed];
    
    // Check for markdown structure
    const headingCount = (trimmed.match(/^#{1,6}\s+.+/gm) || []).length;
    const hasMarkdown = headingCount >= 3;
    
    if (!hasMarkdown) {
      return this.naiveChunkText(trimmed);
    }
    
    return this.semanticChunkText(trimmed);
  }
  
  private naiveChunkText(text: string): string[] {
    const words = text.split(/\s+/).filter(w => w.length > 0);
    if (words.length <= FALLBACK_CHUNK_SIZE) return [text.trim()];
    
    const chunks: string[] = [];
    let start = 0;
    while (start < words.length) {
      const end = Math.min(start + FALLBACK_CHUNK_SIZE, words.length);
      chunks.push(words.slice(start, end).join(' '));
      start = end - FALLBACK_OVERLAP;
      if (start >= words.length - FALLBACK_OVERLAP) break;
    }
    return chunks;
  }
  
  private semanticChunkText(text: string): string[] {
    // Parse sections with heading hierarchy
    const lines = text.split('\n');
    const sections: Array<{ heading: string; content: string; level: number; parentContext: string }> = [];
    let currentHeading: string | null = null;
    let currentLevel = 0;
    let currentLines: string[] = [];
    const headingStack: Array<[number, string]> = [];
    
    for (const line of lines) {
      const match = line.match(/^(#{1,6})\s+(.*)/);
      if (match) {
        // Flush previous section
        if (currentHeading !== null || currentLines.length > 0) {
          const content = currentLines.join('\n').trim();
          if (content) {
            const ctx = headingStack.map(([, h]) => h).join(' > ');
            sections.push({ heading: currentHeading || '', content, level: currentLevel, parentContext: ctx });
          }
        }
        
        const level = match[1].length;
        const headingText = match[2].trim();
        
        while (headingStack.length > 0 && headingStack[headingStack.length - 1][0] >= level) {
          headingStack.pop();
        }
        headingStack.push([level, headingText]);
        
        currentHeading = headingText;
        currentLevel = level;
        currentLines = [];
      } else {
        currentLines.push(line);
      }
    }
    
    // Flush final section
    if (currentLines.length > 0) {
      const content = currentLines.join('\n').trim();
      if (content) {
        const ctx = headingStack.map(([, h]) => h).join(' > ');
        sections.push({ heading: currentHeading || '', content, level: currentLevel, parentContext: ctx });
      }
    }
    
    // Build chunks from sections
    const rawChunks: string[] = [];
    for (const section of sections) {
      const prefix = this.buildPrefix(section.parentContext, section.heading);
      const sectionWords = section.content.split(/\s+/);
      
      if (sectionWords.length <= MAX_CHUNK_WORDS) {
        rawChunks.push(prefix ? `${prefix}\n${section.content}` : section.content);
      } else {
        const paragraphs = section.content.split(/\n\n+/);
        let currentParas: string[] = [];
        let currentWc = 0;
        
        for (const para of paragraphs) {
          const paraWc = para.split(/\s+/).length;
          
          if (paraWc > MAX_CHUNK_WORDS) {
            if (currentParas.length > 0) {
              const chunkContent = currentParas.join('\n\n');
              rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
              currentParas = [];
              currentWc = 0;
            }
            const pWords = para.split(/\s+/);
            for (let j = 0; j < pWords.length; j += MAX_CHUNK_WORDS) {
              const sub = pWords.slice(j, j + MAX_CHUNK_WORDS).join(' ');
              rawChunks.push(prefix ? `${prefix}\n${sub}` : sub);
            }
          } else if (currentWc + paraWc > MAX_CHUNK_WORDS) {
            const chunkContent = currentParas.join('\n\n');
            rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
            currentParas = [para];
            currentWc = paraWc;
          } else {
            currentParas.push(para);
            currentWc += paraWc;
          }
        }
        if (currentParas.length > 0) {
          const chunkContent = currentParas.join('\n\n');
          rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
        }
      }
    }
    
    // Merge small chunks
    return this.mergeSmallChunks(rawChunks);
  }
  
  private buildPrefix(ctx: string, heading: string): string {
    if (ctx && heading && !ctx.includes(heading)) return `[${ctx} > ${heading}]`;
    if (ctx) return `[${ctx}]`;
    if (heading) return `[${heading}]`;
    return '';
  }
  
  private mergeSmallChunks(chunks: string[]): string[] {
    let result = [...chunks];
    for (let pass = 0; pass < 5; pass++) {
      const merged: string[] = [];
      let i = 0;
      while (i < result.length) {
        const chunk = result[i];
        const wc = chunk.split(/\s+/).length;
        
        if (wc < MIN_CHUNK_WORDS && i + 1 < result.length) {
          const combined = chunk + '\n\n' + result[i + 1];
          if (combined.split(/\s+/).length <= MAX_CHUNK_WORDS) {
            merged.push(combined);
            i += 2;
            continue;
          }
        }
        if (wc < MIN_CHUNK_WORDS && merged.length > 0) {
          const combined = merged[merged.length - 1] + '\n\n' + chunk;
          if (combined.split(/\s+/).length <= MAX_CHUNK_WORDS) {
            merged[merged.length - 1] = combined;
            i += 1;
            continue;
          }
        }
        merged.push(chunk);
        i += 1;
      }
      result = merged;
      if (result.every(c => c.split(/\s+/).length >= MIN_CHUNK_WORDS)) break;
    }
    return result;
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Storage Quota Check
  // ─────────────────────────────────────────────────────────────────────────
  
  private async checkStorageQuota(userId: string): Promise<{ totalBytes: number }> {
    try {
      const response = await fetch(
        `${this.env.SUPABASE_URL}/rest/v1/rpc/get_user_storage_bytes`,
        {
          method: 'POST',
          headers: {
            'apikey': this.env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${this.env.SUPABASE_SERVICE_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_user_id: userId }),
        }
      );
      
      if (!response.ok) return { totalBytes: 0 };
      
      const totalBytes = (await response.json()) as number;
      return { totalBytes };
    } catch {
      return { totalBytes: 0 };
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Insert Upload Trace
  // ─────────────────────────────────────────────────────────────────────────
  
  private async insertUploadTrace(): Promise<void> {
    if (this.env.LOG_ENABLED !== 'true') return;
    
    try {
      await fetch(`${this.env.SUPABASE_URL}/rest/v1/upload_traces`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': this.env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${this.env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=minimal',
        },
        body: JSON.stringify({
          trace_id: this.state.trace_id,
          user_id: this.state.user_id,
          upload_type: this.state.upload_type,
          original_filename: this.state.original_filename,
          file_type: this.state.file_type,
          file_size_bytes: this.state.file_size_bytes,
          tag: this.state.tag,
          status: 'accepted',
          current_step: this.state.current_step,
          request_received_at: this.state.request_received_at,
          user_storage_before_bytes: this.state.user_storage_before_bytes,
          auth_method: this.state.auth_method,
        }),
      });
    } catch (err) {
      console.error('[UploadProcessor] Failed to insert trace:', err);
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Update Upload Trace
  // ─────────────────────────────────────────────────────────────────────────
  
  private async updateUploadTrace(updates: Record<string, any>): Promise<void> {
    if (this.env.LOG_ENABLED !== 'true') return;
    
    // Always include current_step in updates for real-time visibility
    const enrichedUpdates = {
      ...updates,
      current_step: this.state.current_step,
    };
    
    try {
      await fetch(
        `${this.env.SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.${this.state.trace_id}`,
        {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'apikey': this.env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${this.env.SUPABASE_SERVICE_KEY}`,
          },
          body: JSON.stringify(enrichedUpdates),
        }
      );
    } catch (err) {
      console.error('[UploadProcessor] Failed to update trace:', err);
    }
  }
  
  // ─────────────────────────────────────────────────────────────────────────
  // Helper: Update Step with Trace Sync
  // ─────────────────────────────────────────────────────────────────────────
  
  private async setStep(step: UploadStep, additionalUpdates?: Record<string, any>): Promise<void> {
    this.state.current_step = step;
    await this.saveState();
    await this.updateUploadTrace(additionalUpdates || {});
  }
}
