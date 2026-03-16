"""
Authentication API routes.
Handles Supabase Auth callbacks and API key management.
"""

from datetime import datetime, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Request, Query
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field
import httpx
import urllib.parse

from app.core.dependencies import get_current_user, require_admin
from app.services.auth_service import (
    AuthenticatedUser,
    create_api_key,
    list_api_keys,
    revoke_api_key,
    delete_api_key,
)
from app.core.config import get_settings
from app.core.log_decorators import log_activity


router = APIRouter(prefix="/auth", tags=["authentication"])


# ============================================================================
# Request/Response Models
# ============================================================================

class APIKeyCreateRequest(BaseModel):
    """Request to create a new API key."""
    name: str = Field(..., description="Friendly name for the API key", min_length=1, max_length=100)
    scopes: List[str] = Field(default=["read", "write"], description="Permissions for this key")
    expires_in_days: Optional[int] = Field(None, description="Days until expiration (null = never)")


class APIKeyResponse(BaseModel):
    """Response containing API key info (without the actual key)."""
    id: str
    key_prefix: str
    name: str
    scopes: List[str]
    is_active: bool
    created_at: str
    last_used_at: Optional[str]
    expires_at: Optional[str]


class APIKeyCreateResponse(BaseModel):
    """Response after creating an API key (includes the actual key ONCE)."""
    api_key: str = Field(..., description="The API key. Save this - it won't be shown again!")
    key_info: APIKeyResponse


class UserInfoResponse(BaseModel):
    """Current user information."""
    user_id: str
    email: Optional[str]
    is_admin: bool
    auth_method: str
    scopes: List[str]


# ============================================================================
# User Info Endpoints
# ============================================================================

@router.get("/me", response_model=UserInfoResponse)
@log_activity(
    action="get_user_info",
    resource_type="user",
    extract_metadata=lambda args, r: {"auth_method": r.auth_method, "email": r.email}
)
async def get_current_user_info(
    current_user: AuthenticatedUser = Depends(get_current_user),
):
    """
    Get information about the currently authenticated user.
    
    Use this endpoint to verify authentication is working.
    """
    return UserInfoResponse(
        user_id=current_user.user_id,
        email=current_user.email,
        is_admin=current_user.is_admin,
        auth_method=current_user.auth_method,
        scopes=current_user.scopes,
    )


# ============================================================================
# API Key Management Endpoints
# ============================================================================

@router.get("/api-keys", response_model=List[APIKeyResponse])
@log_activity(
    action="list_api_keys",
    resource_type="api_key",
    extract_metadata=lambda args, r: {"key_count": len(r)}
)
async def list_user_api_keys(
    current_user: AuthenticatedUser = Depends(get_current_user),
):
    """
    List all API keys for the current user.
    
    Note: The actual key values are not returned - only metadata.
    """
    keys = await list_api_keys(current_user.user_id)
    return [APIKeyResponse(**key) for key in keys]


@router.post("/api-keys", response_model=APIKeyCreateResponse)
@log_activity(
    action="create_api_key",
    resource_type="api_key",
    extract_resource_id=lambda r: r.key_info.id,
    extract_metadata=lambda args, r: {"key_name": r.key_info.name, "scopes": r.key_info.scopes}
)
async def create_user_api_key(
    request: APIKeyCreateRequest,
    current_user: AuthenticatedUser = Depends(get_current_user),
):
    """
    Create a new API key for the current user.
    
    **IMPORTANT**: The API key is only returned ONCE in this response.
    Store it securely - you cannot retrieve it again!
    
    Use API keys for:
    - MCP Server (Claude Desktop integration)
    - CLI tools
    - External integrations
    """
    # Validate scopes
    valid_scopes = {"read", "write", "admin"}
    for scope in request.scopes:
        if scope not in valid_scopes:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid scope: {scope}. Valid scopes: {valid_scopes}"
            )
    
    # Only admins can create keys with admin scope
    if "admin" in request.scopes and not current_user.is_admin:
        raise HTTPException(
            status_code=403,
            detail="Only admins can create keys with admin scope"
        )
    
    # Calculate expiration
    expires_at = None
    if request.expires_in_days:
        from datetime import timedelta
        expires_at = datetime.now(timezone.utc) + timedelta(days=request.expires_in_days)
    
    # Create the key
    full_key, key_record = await create_api_key(
        user_id=current_user.user_id,
        name=request.name,
        scopes=request.scopes,
        expires_at=expires_at,
    )
    
    return APIKeyCreateResponse(
        api_key=full_key,
        key_info=APIKeyResponse(**key_record),
    )


@router.delete("/api-keys/{key_id}")
@log_activity(
    action="delete_api_key",
    resource_type="api_key",
    extract_metadata=lambda args, r: {"key_id": args.get("key_id")}
)
async def delete_user_api_key(
    key_id: str,
    current_user: AuthenticatedUser = Depends(get_current_user),
):
    """
    Permanently delete an API key.
    
    This action cannot be undone.
    """
    success = await delete_api_key(current_user.user_id, key_id)
    
    if not success:
        raise HTTPException(
            status_code=404,
            detail="API key not found or already deleted"
        )
    
    return {"message": "API key deleted successfully"}


@router.post("/api-keys/{key_id}/revoke")
@log_activity(
    action="revoke_api_key",
    resource_type="api_key",
    extract_metadata=lambda args, r: {"key_id": args.get("key_id")}
)
async def revoke_user_api_key(
    key_id: str,
    current_user: AuthenticatedUser = Depends(get_current_user),
):
    """
    Revoke (deactivate) an API key without deleting it.
    
    The key will no longer work for authentication but the record
    is kept for audit purposes.
    """
    success = await revoke_api_key(current_user.user_id, key_id)
    
    if not success:
        raise HTTPException(
            status_code=404,
            detail="API key not found"
        )
    
    return {"message": "API key revoked successfully"}


# ============================================================================
# Supabase Auth Info (for frontend reference)
# ============================================================================

@router.get("/config")
async def get_auth_config():
    """
    Get the Supabase authentication configuration.
    
    Frontend can use this to initialize Supabase Auth client.
    """
    settings = get_settings()
    if not settings.supabase_url or not settings.supabase_anon_key:
        raise HTTPException(
            status_code=503,
            detail="Authentication not configured"
        )
    
    return {
        "supabase_url": settings.supabase_url,
        "supabase_anon_key": settings.supabase_anon_key,
        "providers": ["google"],  # Available OAuth providers
    }


# ============================================================================
# Chrome Extension OAuth Flow
# ============================================================================

@router.get("/chrome-extension/login")
async def chrome_extension_login(
    extension_id: str = Query(..., description="Chrome extension ID for callback"),
):
    """
    Start OAuth flow for Chrome extension.
    
    Redirects to Google OAuth via Supabase, then back to the extension.
    """
    settings = get_settings()
    
    # Build the callback URL that Supabase will redirect to after OAuth
    callback_url = f"http://localhost:8000/api/v1/auth/chrome-extension/callback?extension_id={extension_id}"
    
    # Build Supabase OAuth URL with prompt=select_account to force account picker
    oauth_url = (
        f"{settings.supabase_url}/auth/v1/authorize?"
        f"provider=google&"
        f"redirect_to={urllib.parse.quote(callback_url)}&"
        f"options={{\"queryParams\":{{\"prompt\":\"select_account\"}}}}"
    )
    
    return RedirectResponse(url=oauth_url)


@router.get("/chrome-extension/callback")
async def chrome_extension_callback(
    extension_id: str = Query(..., description="Chrome extension ID"),
    access_token: Optional[str] = Query(None),
    refresh_token: Optional[str] = Query(None),
    error: Optional[str] = Query(None),
    error_description: Optional[str] = Query(None),
):
    """
    Handle OAuth callback from Supabase for Chrome extension.
    
    Generates an API key and redirects to the extension's callback page.
    """
    settings = get_settings()
    
    if error:
        # Redirect to extension with error
        error_url = f"chrome-extension://{extension_id}/callback.html?error={urllib.parse.quote(error_description or error)}"
        return RedirectResponse(url=error_url)
    
    if not access_token:
        # No token in query params - show page to extract from hash fragment
        return HTMLResponse(content=f"""
<!DOCTYPE html>
<html>
<head><title>Completing login...</title></head>
<body>
    <p>Completing authentication...</p>
    <script>
        // Supabase returns tokens in URL hash fragment
        const hash = window.location.hash.substring(1);
        const params = new URLSearchParams(hash);
        const accessToken = params.get('access_token');
        const error = params.get('error');
        
        if (error) {{
            window.location.href = 'chrome-extension://{extension_id}/callback.html?error=' + encodeURIComponent(error);
        }} else if (accessToken) {{
            // Redirect to server endpoint with token in query param
            window.location.href = '/api/v1/auth/chrome-extension/exchange?extension_id={extension_id}&access_token=' + accessToken;
        }} else {{
            window.location.href = 'chrome-extension://{extension_id}/callback.html?error=no_token';
        }}
    </script>
</body>
</html>
        """)
    
    # We have the access token, exchange it for an API key
    return RedirectResponse(
        url=f"/api/v1/auth/chrome-extension/exchange?extension_id={extension_id}&access_token={access_token}"
    )


@router.get("/chrome-extension/exchange")
async def chrome_extension_exchange(
    extension_id: str = Query(..., description="Chrome extension ID"),
    access_token: str = Query(..., description="Supabase access token"),
):
    """
    Exchange Supabase access token for a NotesApp API key.
    
    Verifies the token with Supabase, creates an API key, and shows success page.
    """
    settings = get_settings()
    
    try:
        # Verify the access token with Supabase
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{settings.supabase_url}/auth/v1/user",
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "apikey": settings.supabase_anon_key,
                }
            )
        
        if response.status_code != 200:
            return HTMLResponse(content=_auth_result_page(
                success=False,
                error="Invalid or expired token. Please try again."
            ))
        
        user_data = response.json()
        user_id = user_data.get("id")
        email = user_data.get("email", "")
        
        if not user_id:
            return HTMLResponse(content=_auth_result_page(
                success=False,
                error="Could not retrieve user information."
            ))
        
        # Create an API key for this user
        api_key, key_record = await create_api_key(
            user_id=user_id,
            name=f"Chrome Extension ({email})",
            scopes=["read", "write"],
            expires_at=None,  # No expiration for extension keys
        )
        
        # Return success page with API key
        return HTMLResponse(content=_auth_result_page(
            success=True,
            api_key=api_key,
            email=email,
            extension_id=extension_id
        ))
        
    except Exception as e:
        return HTMLResponse(content=_auth_result_page(
            success=False,
            error=str(e)
        ))


def _auth_result_page(
    success: bool,
    api_key: str = "",
    email: str = "",
    extension_id: str = "",
    error: str = ""
) -> str:
    """Generate the auth result HTML page."""
    if success:
        # Minimal page - content script will capture API key and close tab
        return f"""
<!DOCTYPE html>
<html>
<head>
    <title>NotesApp - Login Successful</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 500px;
            margin: 50px auto;
            padding: 20px;
            text-align: center;
            background: #f0fdf4;
        }}
        .card {{
            background: white;
            border-radius: 12px;
            padding: 40px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        .success {{ color: #22c55e; font-size: 48px; }}
        .message {{ color: #374151; margin-top: 20px; }}
        .email {{ color: #64748b; font-size: 14px; margin-top: 10px; }}
        .api-key {{ display: none; }}
        .spinner {{
            border: 3px solid #e5e7eb;
            border-top: 3px solid #22c55e;
            border-radius: 50%;
            width: 24px;
            height: 24px;
            animation: spin 1s linear infinite;
            margin: 20px auto;
        }}
        @keyframes spin {{
            0% {{ transform: rotate(0deg); }}
            100% {{ transform: rotate(360deg); }}
        }}
        .fallback {{ display: none; margin-top: 20px; }}
        .fallback button {{
            background: #3b82f6;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
            margin: 5px;
        }}
        .fallback button:hover {{ background: #2563eb; }}
    </style>
</head>
<body>
    <div class="card">
        <div class="success">✓</div>
        <h2>Login Successful!</h2>
        <p class="email">Logged in as: <strong>{email}</strong></p>
        <div class="spinner" id="spinner"></div>
        <p class="message" id="status">Connecting to extension...</p>
        
        <!-- Hidden API key for content script to read -->
        <div class="api-key" id="apiKey">{api_key}</div>
        
        <!-- Fallback if content script doesn't work -->
        <div class="fallback" id="fallback">
            <p>Copy this API key to the extension settings:</p>
            <input type="text" value="{api_key}" id="apiKeyInput" readonly 
                   style="width:100%;padding:10px;font-family:monospace;margin:10px 0;border:2px solid #f59e0b;border-radius:4px;">
            <button onclick="copyAndClose()">📋 Copy & Close</button>
        </div>
    </div>
    
    <script>
        // Show fallback after 3 seconds if extension hasn't captured key
        setTimeout(function() {{
            document.getElementById('spinner').style.display = 'none';
            document.getElementById('status').textContent = 'Extension not detected. Copy the key manually:';
            document.getElementById('fallback').style.display = 'block';
        }}, 3000);
        
        function copyAndClose() {{
            const input = document.getElementById('apiKeyInput');
            input.select();
            document.execCommand('copy');
            navigator.clipboard.writeText(input.value);
            alert('API Key copied! Paste it in the extension settings.');
            window.close();
        }}
    </script>
</body>
</html>
"""
    else:
        return f"""
<!DOCTYPE html>
<html>
<head>
    <title>NotesApp - Login Failed</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 500px;
            margin: 50px auto;
            padding: 20px;
            text-align: center;
        }}
        .error {{ color: #ef4444; }}
        .card {{
            background: #fef2f2;
            border-radius: 12px;
            padding: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        .error-msg {{
            background: #fee2e2;
            padding: 15px;
            border-radius: 8px;
            margin: 20px 0;
        }}
        button {{
            background: #3b82f6;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
        }}
        button:hover {{ background: #2563eb; }}
    </style>
</head>
<body>
    <div class="card">
        <h1 class="error">❌ Login Failed</h1>
        <div class="error-msg">{error}</div>
        <button onclick="window.close()">Close Window</button>
    </div>
</body>
</html>
"""
