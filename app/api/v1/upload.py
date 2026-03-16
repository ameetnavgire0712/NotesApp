"""
Upload API endpoints
Handles file uploads, screenshots, and quick notes
"""
import asyncio
from fastapi import APIRouter, UploadFile, File, Form, HTTPException, BackgroundTasks, Depends
from typing import Optional
import mimetypes
import time
import logging

from app.models.schemas import (
    QuickNoteRequest,
    UploadResponse,
    ErrorResponse
)
from app.services.blob_storage import get_blob_service
from app.services.tensorlake import get_tensorlake_service
from app.services.embeddings import get_embeddings_service
from app.services.notes_db import get_notes_db_service
from app.services.title_generator import get_title_generator_service
from app.services.vectorize_worker_service import get_vectorize_worker_service
from app.core.config import get_settings
from app.core.log_decorators import log_activity, log_operation
from app.core.exceptions import BlobStorageError, ExternalServiceError
from app.core.dependencies import require_write_scope
from app.services.auth_service import AuthenticatedUser

router = APIRouter(prefix="/upload", tags=["Upload"])

logger = logging.getLogger(__name__)


# File extensions that can be read directly without TensorLake conversion
PLAIN_TEXT_EXTENSIONS = {'.txt', '.md', '.markdown', '.csv', '.json', '.xml', '.yaml', '.yml', '.log', '.ini', '.cfg', '.conf', '.py', '.js', '.ts', '.html', '.css', '.sql', '.sh', '.bat', '.ps1', '.env', '.gitignore', '.dockerignore'}

def is_plain_text_file(filename: str, content_type: str) -> bool:
    """Check if file is plain text and can skip TensorLake conversion."""
    if not filename:
        return False
    ext = '.' + filename.lower().split('.')[-1] if '.' in filename else ''
    if ext in PLAIN_TEXT_EXTENSIONS:
        return True
    # Also check content type
    if content_type and content_type.startswith('text/'):
        return True
    return False


async def process_and_store_note(
    file_content: bytes,
    filename: str,
    content_type: str,
    file_type: str,
    tag: Optional[str],
    title: Optional[str],
    user_id: str
) -> dict:
    """
    Full pipeline: Upload to blob → Convert to markdown → HTML cleanup → Generate embeddings → Store in DB
    
    Error handling: If any step fails, downstream steps are skipped and error is propagated.
    Pipeline order:
    1. Blob upload (parallel with step 2)
    2. TensorLake conversion (parallel with step 1)
    3. HTML cleanup (only if step 2 succeeds)
    4. Embeddings generation (only if step 3 succeeds)
    5. Database insert (only if step 4 succeeds)
    """
    total_start = time.time()
    logger.debug(f"=== UPLOAD PIPELINE START === filename='{filename}', type={file_type}, size={len(file_content)} bytes, user={user_id}")
    
    blob_service = get_blob_service()
    tensorlake_service = get_tensorlake_service()
    embeddings_service = get_embeddings_service()
    notes_db_service = get_notes_db_service()
    
    blob_result = None
    conversion_result = None
    markdown_content = None
    embedding_result = None
    
    # =========================================================================
    # STEP 1 & 2: Blob upload and TensorLake conversion in PARALLEL
    # =========================================================================
    async def upload_to_azure():
        start = time.time()
        try:
            result = await blob_service.upload_file(
                file_content=file_content,
                user_id=user_id,
                file_type=file_type,
                original_filename=filename if file_type == "uploaded_file" else None,
                content_type=content_type
            )
            logger.info(f"⏱️ Azure upload took: {time.time() - start:.2f}s")
            return {"success": True, "data": result, "error": None}
        except Exception as e:
            logger.error(f"❌ Blob upload failed: {str(e)}")
            return {"success": False, "data": None, "error": str(e)}
    
    async def convert_with_tensorlake():
        start = time.time()
        try:
            # Skip TensorLake for plain text files - read directly
            if is_plain_text_file(filename, content_type) and file_type != "screenshot":
                try:
                    text_content = file_content.decode('utf-8')
                except UnicodeDecodeError:
                    try:
                        text_content = file_content.decode('latin-1')
                    except Exception:
                        text_content = file_content.decode('utf-8', errors='replace')
                logger.info(f"⏱️ Plain text file detected, skipping TensorLake (took {time.time() - start:.3f}s)")
                return {
                    "success": True,
                    "markdown": text_content,
                    "metadata": {"type": "plain_text", "skipped_tensorlake": True},
                    "page_count": 1,
                    "error": None
                }
            
            if file_type == "screenshot":
                result = await tensorlake_service.process_image(file_content, filename)
            else:
                result = await tensorlake_service.convert_to_markdown(
                    file_content, filename, content_type
                )
            logger.info(f"⏱️ Tensorlake conversion took: {time.time() - start:.2f}s")
            return result
        except Exception as e:
            logger.error(f"❌ TensorLake conversion failed: {str(e)}")
            return {"success": False, "markdown": "", "error": str(e), "page_count": 0}
    
    # Execute both in parallel
    parallel_start = time.time()
    logger.debug("Starting parallel operations: Azure blob upload + TensorLake conversion")
    blob_response, conversion_result = await asyncio.gather(
        upload_to_azure(),
        convert_with_tensorlake()
    )
    logger.info(f"⏱️ Parallel ops (Azure + Tensorlake) took: {time.time() - parallel_start:.2f}s")
    logger.debug(f"Blob upload success: {blob_response['success']}, Conversion success: {conversion_result.get('success', False)}")
    
    # =========================================================================
    # CHECK STEP 1: Blob upload result
    # =========================================================================
    if not blob_response["success"]:
        raise BlobStorageError(f"Blob upload failed: {blob_response['error']}")
    
    blob_result = blob_response["data"]
    
    # =========================================================================
    # CHECK STEP 2: TensorLake conversion result
    # =========================================================================
    if not conversion_result["success"]:
        raise ExternalServiceError(
            service="tensorlake",
            message=f"Document conversion failed: {conversion_result.get('error', 'Unknown error')}"
        )
    
    markdown_content = conversion_result["markdown"]
    logger.debug(f"Markdown content received, length: {len(markdown_content)} chars")
    
    # =========================================================================
    # STEP 3: HTML cleanup (only runs if conversion succeeded)
    # =========================================================================
    try:
        from app.services.html_cleaner import get_html_cleaner
        html_cleaner = get_html_cleaner()
        if html_cleaner.has_html_content(markdown_content):
            clean_start = time.time()
            logger.debug("HTML content detected, starting cleanup")
            markdown_content = html_cleaner.clean_content(markdown_content)
            logger.info(f"⏱️ HTML cleanup took: {time.time() - clean_start:.2f}s")
            logger.debug(f"After HTML cleanup, markdown length: {len(markdown_content)} chars")
        else:
            logger.debug("No HTML detected, skipping cleanup")
    except Exception as e:
        logger.error(f"❌ HTML cleanup failed: {str(e)}")
        raise ExternalServiceError(service="html_cleaner", message=f"HTML cleanup failed: {str(e)}")
    
    # =========================================================================
    # STEP 3.5: Generate descriptive title using LLM (if no title provided)
    # =========================================================================
    # Check if a meaningful title was provided (ignore placeholder values like "string")
    has_valid_title = title and title.strip() and title.strip().lower() not in ("string", "title", "")
    
    if has_valid_title:
        # Use provided title
        auto_title = title.strip()
        logger.debug(f"Using provided title: '{auto_title[:50]}...'")
    else:
        # Generate title using LLM
        try:
            title_start = time.time()
            logger.debug("No title provided, generating via LLM")
            title_generator = get_title_generator_service()
            auto_title = await title_generator.generate_title(
                content_markdown=markdown_content,
                filename=filename
            )
            logger.info(f"⏱️ LLM title generation took: {time.time() - title_start:.2f}s")
            logger.debug(f"Generated title: '{auto_title[:80]}...'")
        except Exception as e:
            logger.warning(f"⚠️ Title generation failed, using fallback: {str(e)}")
            auto_title = filename or f"{file_type}_{blob_result['blob_name'].split('/')[-1]}"
    
    # =========================================================================
    # STEP 4: Generate embeddings (only runs if HTML cleanup succeeded)
    # =========================================================================
    try:
        embed_start = time.time()
        logger.debug(f"Generating embeddings for content length: {len(markdown_content)} chars")
        embedding_result = await embeddings_service.process_document(
            markdown_content=markdown_content,
            title=auto_title
        )
        logger.info(f"⏱️ OpenAI embeddings took: {time.time() - embed_start:.2f}s")
        logger.debug(f"Embeddings generated: doc_embedding dim={len(embedding_result.get('document_embedding', []))}, chunks={len(embedding_result.get('chunks', []))}")
    except Exception as e:
        logger.error(f"❌ Embeddings generation failed: {str(e)}")
        raise ExternalServiceError(service="openai", message=f"Embeddings generation failed: {str(e)}")
    
    # =========================================================================
    # STEP 5: Store in Supabase (only runs if embeddings succeeded)
    # =========================================================================
    try:
        db_start = time.time()
        logger.debug(f"Inserting note into database for user: {user_id}")
        note = await notes_db_service.create_note(
            user_id=user_id,
            title=auto_title,
            content_markdown=markdown_content,
            tag=tag,
            file_type=file_type,
            original_filename=filename if file_type == "uploaded_file" else None,
            blob_url=blob_result["blob_url"],
            embedding=embedding_result["document_embedding"],
            metadata={
                "blob_name": blob_result["blob_name"],
                "size_bytes": blob_result["size_bytes"],
                "conversion_success": True,
                "page_count": conversion_result.get("page_count", 1)
            }
        )
        
        # Store chunks in Vectorize only (removed redundant Supabase note_chunks write)
        chunks_created = 0
        if embedding_result["chunks"]:
            chunks_created = len(embedding_result["chunks"])
            logger.debug(f"Storing {chunks_created} chunks for note {note['id']} in Vectorize")
            
            # =========================================================================
            # STEP 5b: Update Vectorize index with new chunks (for real-time search)
            # Vectorize is the sole vector store - no Supabase note_chunks table
            # =========================================================================
            try:
                vectorize_start = time.time()
                worker_service = get_vectorize_worker_service()
                
                # Prepare vectors for Worker API
                # Note: Vectorize allows 10KB metadata per vector, chunks are typically <3KB
                vectorize_vectors = []
                for i, chunk in enumerate(embedding_result["chunks"]):
                    chunk_id = chunk.get("chunk_id", f"{note['id']}_{i}")
                    vectorize_vectors.append({
                        "id": chunk_id,
                        "values": chunk["embedding"],
                        "metadata": {
                            "note_id": note["id"],
                            "chunk_index": i,
                            "content": chunk.get("content", ""),  # Full chunk content for reranking
                            "title": auto_title,
                            "tag": tag or "",
                            "file_type": file_type,
                            "blob_url": blob_result["blob_url"],
                            "user_id": user_id
                        }
                    })
                
                await worker_service.upsert(vectorize_vectors)
                logger.info(f"⏱️ Vectorize upsert took: {time.time() - vectorize_start:.2f}s ({chunks_created} vectors)")
                
                # Invalidate search cache for this user (so new doc appears in searches)
                try:
                    await worker_service.invalidate_user_cache(user_id, cache_type="search")
                    logger.info(f"✓ Search cache invalidated for user {user_id[:8]}...")
                except Exception as cache_err:
                    logger.warning(f"⚠️ Cache invalidation failed (non-critical): {cache_err}")
            except Exception as e:
                # Vectorize update failure is non-fatal - log warning but don't fail the upload
                logger.warning(f"⚠️ Vectorize upsert failed (upload still succeeded): {str(e)}")
        
        logger.info(f"⏱️ Supabase DB operations took: {time.time() - db_start:.2f}s")
        logger.debug(f"Note created: id={note['id']}, chunks={chunks_created}")
    except Exception as e:
        logger.error(f"❌ Database insert failed: {str(e)}")
        raise ExternalServiceError(service="supabase", message=f"Database insert failed: {str(e)}")
    
    total_duration = time.time() - total_start
    logger.info(f"⏱️ TOTAL upload pipeline took: {total_duration:.2f}s")
    logger.debug(f"=== UPLOAD PIPELINE COMPLETE === note_id={note['id']}, chunks={chunks_created}, duration={total_duration:.2f}s")
    
    return {
        "note_id": note["id"],
        "blob_url": blob_result["blob_url"],
        "chunks_created": chunks_created
    }


@router.post("/file", response_model=UploadResponse)
@log_activity(
    action="upload_file",
    resource_type="file",
    extract_resource_id=lambda r: r.note_id if hasattr(r, 'note_id') else None,
    extract_metadata=lambda args, r: {
        "filename": args.get("file", {}).filename if hasattr(args.get("file", {}), "filename") else None,
        "chunks_created": r.chunks_created if hasattr(r, 'chunks_created') else 0
    }
)
async def upload_file(
    file: UploadFile = File(..., description="File to upload (PDF, Word, Excel, image, text)"),
    tag: Optional[str] = Form(None, description="Category/tag for the file"),
    title: Optional[str] = Form(None, description="Optional title - if not provided, AI will generate a descriptive title"),
    current_user: AuthenticatedUser = Depends(require_write_scope)
):
    """
    Upload a file (PDF, Word, Excel, image, text file)
    
    The file will be:
    1. Stored in Azure Blob Storage
    2. Converted to markdown using Tensorlake
    3. Embedded using OpenAI
    4. Stored in Supabase with vector for semantic search
    
    **Requires authentication** (Bearer token or API key with 'write' scope)
    """
    try:
        file_content = await file.read()
        
        if not file_content:
            raise HTTPException(status_code=400, detail="Empty file")
        
        # Determine content type
        content_type = file.content_type or mimetypes.guess_type(file.filename)[0] or "application/octet-stream"
        
        result = await process_and_store_note(
            file_content=file_content,
            filename=file.filename,
            content_type=content_type,
            file_type="uploaded_file",
            tag=tag,
            title=title,
            user_id=current_user.user_id
        )
        
        return UploadResponse(
            success=True,
            note_id=result["note_id"],
            message="File uploaded and processed successfully",
            blob_url=result["blob_url"],
            chunks_created=result["chunks_created"]
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Upload failed: {str(e)}")


@router.post("/screenshot", response_model=UploadResponse)
@log_activity(
    action="upload_screenshot",
    resource_type="screenshot",
    extract_resource_id=lambda r: r.note_id if hasattr(r, 'note_id') else None,
    extract_metadata=lambda args, r: {"chunks_created": r.chunks_created if hasattr(r, 'chunks_created') else 0}
)
async def upload_screenshot(
    file: UploadFile = File(..., description="Screenshot image"),
    tag: Optional[str] = Form(None, description="Category/tag for the screenshot"),
    title: Optional[str] = Form(None, description="Optional title for the screenshot"),
    current_user: AuthenticatedUser = Depends(require_write_scope)
):
    """
    Upload a screenshot image
    
    The screenshot will be:
    1. Stored in Azure Blob Storage
    2. Processed by Tensorlake for text/content extraction
    3. Embedded using OpenAI
    4. Stored in Supabase for semantic search
    
    **Requires authentication** (Bearer token or API key with 'write' scope)
    """
    try:
        file_content = await file.read()
        
        if not file_content:
            raise HTTPException(status_code=400, detail="Empty file")
        
        # Validate it's an image
        content_type = file.content_type or "image/png"
        if not content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="File must be an image")
        
        filename = file.filename or "screenshot.png"
        
        result = await process_and_store_note(
            file_content=file_content,
            filename=filename,
            content_type=content_type,
            file_type="screenshot",
            tag=tag,
            title=title,
            user_id=current_user.user_id
        )
        
        return UploadResponse(
            success=True,
            note_id=result["note_id"],
            message="Screenshot uploaded and processed successfully",
            blob_url=result["blob_url"],
            chunks_created=result["chunks_created"]
        )
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Upload failed: {str(e)}")


@router.post("/quick-note", response_model=UploadResponse)
@log_activity(
    action="create_quick_note",
    resource_type="quick_note",
    extract_resource_id=lambda r: r.note_id if hasattr(r, 'note_id') else None,
    extract_metadata=lambda args, r: {"chunks_created": r.chunks_created if hasattr(r, 'chunks_created') else 0}
)
async def create_quick_note(
    request: QuickNoteRequest,
    current_user: AuthenticatedUser = Depends(require_write_scope)
):
    """
    Create a quick text note
    
    The note will be:
    1. Stored in Azure Blob Storage as a text file
    2. Embedded using OpenAI
    3. Stored in Supabase for semantic search
    
    **Requires authentication** (Bearer token or API key with 'write' scope)
    """
    try:
        tensorlake_service = get_tensorlake_service()
        blob_service = get_blob_service()
        embeddings_service = get_embeddings_service()
        notes_db_service = get_notes_db_service()
        
        # Process as markdown (no Tensorlake API needed)
        conversion_result = tensorlake_service.process_quick_note(
            text_content=request.content,
            title=request.title
        )
        
        markdown_content = conversion_result["markdown"]
        
        # Store the text in blob storage
        file_content = markdown_content.encode("utf-8")
        blob_result = await blob_service.upload_file(
            file_content=file_content,
            user_id=current_user.user_id,
            file_type="quick_note",
            content_type="text/markdown"
        )
        
        # Generate embeddings
        auto_title = request.title or request.content[:50] + "..." if len(request.content) > 50 else request.content
        
        embedding_result = await embeddings_service.process_document(
            markdown_content=markdown_content,
            title=auto_title
        )
        
        # Store in database
        note = await notes_db_service.create_note(
            user_id=current_user.user_id,
            title=auto_title,
            content_markdown=markdown_content,
            tag=request.tag,
            file_type="quick_note",
            original_filename=None,
            blob_url=blob_result["blob_url"],
            embedding=embedding_result["document_embedding"],
            metadata={
                "blob_name": blob_result["blob_name"],
                "size_bytes": blob_result["size_bytes"]
            }
        )
        
        # Store chunks in Vectorize only (removed redundant Supabase note_chunks write)
        chunks_created = 0
        if embedding_result["chunks"]:
            chunks_created = len(embedding_result["chunks"])
            
            # STEP: Upsert to Vectorize for real-time search (sole vector store)
            try:
                worker_service = get_vectorize_worker_service()
                
                # Prepare vectors for Worker API
                # Note: Vectorize allows 10KB metadata per vector, chunks are typically <3KB
                vectorize_vectors = []  
                for i, chunk in enumerate(embedding_result["chunks"]):
                    chunk_id = chunk.get("chunk_id", f"{note['id']}_{i}")
                    vectorize_vectors.append({
                        "id": chunk_id,
                        "values": chunk["embedding"],
                        "metadata": {
                            "note_id": note["id"],
                            "chunk_index": i,
                            "content": chunk.get("content", ""),  # Full chunk content for reranking
                            "title": auto_title,
                            "tag": request.tag or "",
                            "file_type": "quick_note",
                            "blob_url": blob_result["blob_url"],
                            "user_id": current_user.user_id
                        }
                    })
                
                await worker_service.upsert(vectorize_vectors)
                logger.info(f"✓ Vectorize upsert: {chunks_created} vectors for quick-note {note['id'][:8]}...")
                
                # Invalidate search cache so new note appears immediately
                try:
                    await worker_service.invalidate_user_cache(current_user.user_id, cache_type="search")
                    logger.info(f"✓ Search cache invalidated for user {current_user.user_id[:8]}...")
                except Exception as cache_err:
                    logger.warning(f"⚠️ Cache invalidation failed (non-critical): {cache_err}")
            except Exception as e:
                # Vectorize failure is non-fatal - note is saved, just won't appear in vector search immediately
                logger.warning(f"⚠️ Vectorize upsert failed for quick-note (non-critical): {str(e)}")
        
        return UploadResponse(
            success=True,
            note_id=note["id"],
            message="Quick note created successfully",
            blob_url=blob_result["blob_url"],
            chunks_created=chunks_created
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create note: {str(e)}")
