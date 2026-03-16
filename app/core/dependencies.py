"""
FastAPI dependencies for authentication.
Provides reusable dependencies to protect API endpoints.
"""

import logging
import time
from typing import Optional
from fastapi import Depends, HTTPException, Header, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from app.services.auth_service import (
    AuthenticatedUser,
    AuthError,
    verify_supabase_jwt,
    verify_api_key,
)

logger = logging.getLogger(__name__)


# HTTP Bearer token extractor
bearer_scheme = HTTPBearer(auto_error=False)


async def get_current_user(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
) -> AuthenticatedUser:
    """
    Get the current authenticated user.
    
    Supports two authentication methods:
    1. Bearer token (JWT from Supabase Auth) - for web/extension
    2. API Key (X-API-Key header) - for MCP server/CLI tools
    
    Raises:
        HTTPException(401): If no valid authentication provided
    """
    start_time = time.time()
    method = request.method
    path = request.url.path
    
    logger.info(f"🔘 Request received: {method} {path}")
    
    # Try API Key first (header takes precedence for MCP compatibility)
    if x_api_key:
        logger.info(f"   🔑 Auth method: API Key (X-API-Key header)")
        try:
            user = await verify_api_key(x_api_key)
            elapsed = (time.time() - start_time) * 1000
            logger.info(f"   ✅ API Key valid - user_id: {user.user_id[:8]}... ({elapsed:.1f}ms)")
            return user
        except AuthError as e:
            elapsed = (time.time() - start_time) * 1000
            logger.warning(f"   ❌ API Key invalid: {e.message} ({elapsed:.1f}ms)")
            raise HTTPException(status_code=e.status_code, detail=e.message)
    
    # Try Bearer token (JWT or API Key)
    if credentials and credentials.credentials:
        token = credentials.credentials
        token_preview = token[:20] + "..." if len(token) > 20 else token
        
        # Check if Bearer token is actually an API key (for MCP remote URL compatibility)
        if token.startswith("na_"):
            logger.info(f"   🔑 Auth method: Bearer token with API Key")
            try:
                user = await verify_api_key(token)
                elapsed = (time.time() - start_time) * 1000
                logger.info(f"   ✅ API Key valid - user_id: {user.user_id[:8]}... ({elapsed:.1f}ms)")
                return user
            except AuthError as e:
                elapsed = (time.time() - start_time) * 1000
                logger.warning(f"   ❌ API Key invalid: {e.message} ({elapsed:.1f}ms)")
                raise HTTPException(status_code=e.status_code, detail=e.message)
        
        # Otherwise treat as Supabase JWT
        logger.info(f"   🎫 Auth method: Bearer token (JWT)")
        try:
            user = await verify_supabase_jwt(token)
            elapsed = (time.time() - start_time) * 1000
            logger.info(f"   ✅ JWT valid - user_id: {user.user_id[:8]}... email: {user.email} ({elapsed:.1f}ms)")
            return user
        except AuthError as e:
            elapsed = (time.time() - start_time) * 1000
            logger.warning(f"   ❌ JWT invalid: {e.message} ({elapsed:.1f}ms)")
            raise HTTPException(status_code=e.status_code, detail=e.message)
    
    # No authentication provided
    elapsed = (time.time() - start_time) * 1000
    logger.warning(f"   ❌ No auth credentials provided for {method} {path} ({elapsed:.1f}ms)")
    raise HTTPException(
        status_code=401,
        detail="Authentication required. Provide a Bearer token or X-API-Key header.",
        headers={"WWW-Authenticate": "Bearer"}
    )


async def get_current_user_optional(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
) -> Optional[AuthenticatedUser]:
    """
    Get the current user if authenticated, None otherwise.
    Use this for endpoints that work differently for authenticated vs anonymous users.
    """
    try:
        return await get_current_user(request, credentials, x_api_key)
    except HTTPException:
        return None


async def require_admin(
    current_user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    """
    Require the current user to be an admin.
    
    Raises:
        HTTPException(403): If user is not an admin
    """
    if not current_user.is_admin:
        raise HTTPException(
            status_code=403,
            detail="Admin access required"
        )
    return current_user


async def require_scope(required_scope: str):
    """
    Factory for creating scope-checking dependencies.
    
    Usage:
        @router.post("/notes")
        async def create_note(user: AuthenticatedUser = Depends(require_scope("write"))):
            ...
    """
    async def check_scope(
        current_user: AuthenticatedUser = Depends(get_current_user),
    ) -> AuthenticatedUser:
        if required_scope not in current_user.scopes:
            raise HTTPException(
                status_code=403,
                detail=f"Scope '{required_scope}' required"
            )
        return current_user
    
    return check_scope


# Convenience dependencies for common scopes
async def require_read_scope(
    current_user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    """Require 'read' scope."""
    if "read" not in current_user.scopes:
        raise HTTPException(status_code=403, detail="Read access required")
    return current_user


async def require_write_scope(
    current_user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    """Require 'write' scope."""
    if "write" not in current_user.scopes:
        raise HTTPException(status_code=403, detail="Write access required")
    return current_user


def get_user_id(current_user: AuthenticatedUser = Depends(get_current_user)) -> str:
    """
    Simple dependency that just returns the user_id string.
    Useful when you only need the user_id, not the full AuthenticatedUser.
    """
    return current_user.user_id
