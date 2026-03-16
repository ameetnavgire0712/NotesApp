"""
Authentication service for NotesApp.
Handles JWT verification (Supabase Auth) and API key validation.
"""

import hashlib
import secrets
import logging
from datetime import datetime, timezone
from typing import Optional, Tuple
from dataclasses import dataclass
from functools import lru_cache
import time

import httpx
from jose import jwt, JWTError

from app.core.config import get_settings
from app.services.notes_db import get_supabase_client

logger = logging.getLogger(__name__)

# Simple in-memory cache for verified tokens (token_hash -> (user_data, expiry_time))
_token_cache: dict[str, Tuple[dict, float]] = {}
TOKEN_CACHE_TTL = 300  # 5 minutes

# API key cache (api_key_hash -> (AuthenticatedUser, expiry_time, key_id))
_api_key_cache: dict[str, Tuple["AuthenticatedUser", float, str]] = {}
API_KEY_CACHE_TTL = 1800  # 30 minutes (API keys rarely change)


def invalidate_api_key_cache(key_id: str) -> bool:
    """
    Invalidate (remove) an API key from the cache by its key_id.
    Used when a key is deleted or revoked.
    
    Returns True if key was found and removed, False otherwise.
    """
    global _api_key_cache
    # Find and remove the cache entry with matching key_id
    for hashed_key, (user, expiry, cached_key_id) in list(_api_key_cache.items()):
        if cached_key_id == key_id:
            del _api_key_cache[hashed_key]
            logger.info(f"      🗑️ API key cache invalidated for key_id: {key_id[:8]}...")
            return True
    logger.debug(f"      ℹ️ API key not in cache (key_id: {key_id[:8]}...)")
    return False


async def warm_api_key_cache() -> int:
    """
    Pre-populate the API key cache with all active keys from database.
    Called on application startup to avoid cold-start auth latency.
    
    Returns the number of keys loaded into cache.
    """
    global _api_key_cache
    logger.info("🔥 Warming up API key cache...")
    
    try:
        supabase = get_supabase_client()
        
        # Load all active, non-expired keys
        result = supabase.table("user_api_keys").select(
            "id, user_id, api_key, scopes, expires_at"
        ).eq("is_active", True).execute()
        
        if not result.data:
            logger.info("   ℹ️ No active API keys found")
            return 0
        
        loaded_count = 0
        now = datetime.now(timezone.utc)
        
        # Collect unique user_ids to batch fetch emails
        user_ids = set()
        valid_keys = []
        
        for key_data in result.data:
            # Skip expired keys
            expires_at = key_data.get("expires_at")
            if expires_at:
                expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
                if expiry < now:
                    continue
            valid_keys.append(key_data)
            user_ids.add(key_data["user_id"])
        
        # Fetch emails for all unique users
        user_emails = {}
        for user_id in user_ids:
            try:
                auth_response = supabase.auth.admin.get_user_by_id(user_id)
                if auth_response and auth_response.user and auth_response.user.email:
                    user_emails[user_id] = auth_response.user.email
                    logger.debug(f"   📧 Fetched email for user {user_id[:8]}...")
            except Exception as e:
                logger.warning(f"   ⚠️ Could not fetch email for user {user_id[:8]}: {e}")
        
        # Now create cached entries with emails
        for key_data in valid_keys:
            hashed_key = key_data["api_key"]  # Already hashed in DB
            key_id = key_data["id"]
            user_id = key_data["user_id"]
            
            user = AuthenticatedUser(
                user_id=user_id,
                email=user_emails.get(user_id),  # Include email from lookup
                auth_method="api_key",
                scopes=key_data.get("scopes", ["read", "write"])
            )
            
            # Add to cache
            _api_key_cache[hashed_key] = (user, time.time() + API_KEY_CACHE_TTL, key_id)
            loaded_count += 1
        
        logger.info(f"   ✅ API key cache warmed with {loaded_count} keys ({len(user_emails)} emails fetched)")
        return loaded_count
        
    except Exception as e:
        logger.warning(f"   ⚠️ Failed to warm API key cache: {e}")
        return 0


def get_api_key_cache_stats() -> dict:
    """Get cache statistics for monitoring/debugging."""
    now = time.time()
    active_keys = sum(1 for _, (_, exp, _) in _api_key_cache.items() if exp > now)
    expired_keys = len(_api_key_cache) - active_keys
    return {
        "total_cached": len(_api_key_cache),
        "active": active_keys,
        "expired": expired_keys,
        "ttl_seconds": API_KEY_CACHE_TTL
    }


@dataclass
class AuthenticatedUser:
    """Represents an authenticated user."""
    user_id: str
    email: Optional[str] = None
    is_admin: bool = False
    auth_method: str = "jwt"  # "jwt" or "api_key"
    scopes: list[str] = None
    
    def __post_init__(self):
        if self.scopes is None:
            self.scopes = ["read", "write"]
        # Check if user is admin
        self.is_admin = self.user_id == get_settings().admin_user_id


class AuthError(Exception):
    """Authentication error with status code."""
    def __init__(self, message: str, status_code: int = 401):
        self.message = message
        self.status_code = status_code
        super().__init__(message)


async def verify_supabase_jwt(token: str) -> AuthenticatedUser:
    """
    Verify a Supabase JWT token.
    
    Supabase JWTs are signed with the JWT secret and contain:
    - sub: user id
    - email: user email
    - exp: expiration timestamp
    - aud: audience (should be "authenticated")
    """
    settings = get_settings()
    if not settings.supabase_jwt_secret:
        # Fallback: Use Supabase API to verify token
        return await verify_jwt_via_supabase_api(token)
    
    try:
        # Decode and verify the JWT
        payload = jwt.decode(
            token,
            settings.supabase_jwt_secret,
            algorithms=["HS256"],
            audience="authenticated"
        )
        
        user_id = payload.get("sub")
        if not user_id:
            raise AuthError("Invalid token: missing user id")
        
        return AuthenticatedUser(
            user_id=user_id,
            email=payload.get("email"),
            auth_method="jwt"
        )
        
    except JWTError as e:
        raise AuthError(f"Invalid token: {str(e)}")


async def verify_jwt_via_supabase_api(token: str) -> AuthenticatedUser:
    """
    Verify JWT by calling Supabase auth API.
    Fallback when JWT secret is not configured.
    Uses caching to avoid calling Supabase API on every request.
    """
    settings = get_settings()
    
    # Check cache first
    token_hash = hashlib.sha256(token.encode()).hexdigest()[:16]
    cached = _token_cache.get(token_hash)
    if cached:
        user_data, expiry = cached
        if time.time() < expiry:
            logger.info(f"      📦 Token CACHE HIT - user {user_data.get('id', 'unknown')[:8]}...")
            return AuthenticatedUser(
                user_id=user_data.get("id"),
                email=user_data.get("email"),
                auth_method="jwt"
            )
        else:
            # Expired, remove from cache
            logger.info(f"      ⏰ Token cache EXPIRED - will re-verify")
            del _token_cache[token_hash]
    else:
        logger.info(f"      📭 Token CACHE MISS - calling Supabase API")
    
    # Call Supabase API with timeout
    start = time.time()
    async with httpx.AsyncClient(timeout=5.0) as client:
        response = await client.get(
            f"{settings.supabase_url}/auth/v1/user",
            headers={
                "Authorization": f"Bearer {token}",
                "apikey": settings.supabase_anon_key or settings.supabase_service_key
            }
        )
        
        elapsed = (time.time() - start) * 1000
        logger.info(f"      🌐 Supabase API: {response.status_code} ({elapsed:.0f}ms)")
        
        if response.status_code != 200:
            raise AuthError("Invalid or expired token")
        
        user_data = response.json()
        
        # Cache the result
        _token_cache[token_hash] = (user_data, time.time() + TOKEN_CACHE_TTL)
        
        # Clean old cache entries (simple cleanup, max 100 entries)
        if len(_token_cache) > 100:
            now = time.time()
            expired_keys = [k for k, (_, exp) in _token_cache.items() if exp < now]
            for k in expired_keys:
                del _token_cache[k]
        
        return AuthenticatedUser(
            user_id=user_data.get("id"),
            email=user_data.get("email"),
            auth_method="jwt"
        )


def hash_api_key(api_key: str) -> str:
    """Hash an API key using SHA-256."""
    return hashlib.sha256(api_key.encode()).hexdigest()


def generate_api_key() -> Tuple[str, str, str]:
    """
    Generate a new API key.
    
    Returns:
        Tuple of (full_key, hashed_key, key_prefix)
        - full_key: The actual key to give to user (only shown once)
        - hashed_key: What we store in the database
        - key_prefix: First 8 chars for identification
    """
    # Generate a secure random key with prefix
    random_part = secrets.token_urlsafe(32)
    full_key = f"na_{random_part}"  # "na_" prefix for "NotesApp"
    
    hashed_key = hash_api_key(full_key)
    key_prefix = full_key[:11]  # "na_" + first 8 chars
    
    return full_key, hashed_key, key_prefix


async def verify_api_key(api_key: str) -> AuthenticatedUser:
    """
    Verify an API key and return the authenticated user.
    Uses caching to avoid repeated database lookups.
    """
    if not api_key or not api_key.startswith("na_"):
        logger.warning(f"      ❌ Invalid API key format")
        raise AuthError("Invalid API key format")
    
    key_prefix = api_key[:11]
    hashed_key = hash_api_key(api_key)
    
    # Check cache first
    cached = _api_key_cache.get(hashed_key)
    if cached:
        user, expiry, cached_key_id = cached
        if time.time() < expiry:
            logger.info(f"      📦 API key CACHE HIT - user {user.user_id[:8]}...")
            return user
        else:
            logger.info(f"      ⏰ API key cache EXPIRED - will re-verify")
            del _api_key_cache[hashed_key]
    else:
        logger.info(f"      🔍 Looking up API key: {key_prefix}...")
    
    # Look up the API key in the database
    supabase = get_supabase_client()
    
    result = supabase.table("user_api_keys").select(
        "id, user_id, name, scopes, is_active, expires_at"
    ).eq("api_key", hashed_key).execute()
    
    if not result.data:
        logger.warning(f"      ❌ API key not found in database")
        raise AuthError("Invalid API key")
    
    key_data = result.data[0]
    logger.info(f"      📋 Found key: '{key_data.get('name')}' for user {key_data['user_id'][:8]}...")
    
    # Check if key is active
    if not key_data.get("is_active", False):
        logger.warning(f"      ❌ API key is deactivated")
        raise AuthError("API key is deactivated")
    
    # Check if key is expired
    expires_at = key_data.get("expires_at")
    if expires_at:
        expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        if expiry < datetime.now(timezone.utc):
            logger.warning(f"      ❌ API key expired at {expires_at}")
            raise AuthError("API key has expired")
    
    # Update last_used_at (async, non-blocking)
    try:
        supabase.table("user_api_keys").update({
            "last_used_at": datetime.now(timezone.utc).isoformat()
        }).eq("api_key", hashed_key).execute()
    except Exception:
        pass  # Non-critical, don't fail auth if this fails
    
    # Look up user email from Supabase auth admin API
    user_email = None
    try:
        auth_response = supabase.auth.admin.get_user_by_id(key_data["user_id"])
        if auth_response and auth_response.user:
            user_email = auth_response.user.email
            logger.info(f"      📧 Found user email: {user_email}")
    except Exception as e:
        logger.warning(f"      ⚠️ Could not fetch user email: {e}")
    
    user = AuthenticatedUser(
        user_id=key_data["user_id"],
        email=user_email,
        auth_method="api_key",
        scopes=key_data.get("scopes", ["read", "write"])
    )
    
    # Cache the result with key_id for invalidation support
    key_id = key_data["id"]
    _api_key_cache[hashed_key] = (user, time.time() + API_KEY_CACHE_TTL, key_id)
    
    # Clean old cache entries
    if len(_api_key_cache) > 100:
        now = time.time()
        expired_keys = [k for k, (_, exp, _) in _api_key_cache.items() if exp < now]
        for k in expired_keys:
            del _api_key_cache[k]
    
    return user


async def create_api_key(
    user_id: str,
    name: str,
    scopes: list[str] = None,
    expires_at: Optional[datetime] = None
) -> Tuple[str, dict]:
    """
    Create a new API key for a user.
    
    Returns:
        Tuple of (full_api_key, key_record)
        - full_api_key: The actual key (only returned once, not stored)
        - key_record: The database record
    """
    if scopes is None:
        scopes = ["read", "write"]
    
    full_key, hashed_key, key_prefix = generate_api_key()
    
    supabase = get_supabase_client()
    
    record = {
        "user_id": user_id,
        "api_key": hashed_key,
        "key_prefix": key_prefix,
        "name": name,
        "scopes": scopes,
        "is_active": True,
        "expires_at": expires_at.isoformat() if expires_at else None
    }
    
    result = supabase.table("user_api_keys").insert(record).execute()
    
    if not result.data:
        raise AuthError("Failed to create API key", status_code=500)
    
    key_record = result.data[0]
    key_id = key_record["id"]
    
    # Add newly created key to cache immediately
    user = AuthenticatedUser(
        user_id=user_id,
        email=None,  # Will be fetched on actual API request if needed
        auth_method="api_key",
        scopes=scopes
    )
    _api_key_cache[hashed_key] = (user, time.time() + API_KEY_CACHE_TTL, key_id)
    logger.info(f"      ➕ New API key added to cache (key_id: {key_id[:8]}...)")
    
    # Don't return the hashed key in the response
    key_record.pop("api_key", None)
    
    return full_key, key_record


async def list_api_keys(user_id: str) -> list[dict]:
    """List all API keys for a user (without the actual keys)."""
    supabase = get_supabase_client()
    
    result = supabase.table("user_api_keys").select(
        "id, key_prefix, name, created_at, last_used_at, expires_at, is_active, scopes"
    ).eq("user_id", user_id).order("created_at", desc=True).execute()
    
    return result.data or []


async def revoke_api_key(user_id: str, key_id: str) -> bool:
    """Revoke (deactivate) an API key and invalidate cache."""
    supabase = get_supabase_client()
    
    result = supabase.table("user_api_keys").update({
        "is_active": False
    }).eq("id", key_id).eq("user_id", user_id).execute()
    
    success = len(result.data) > 0 if result.data else False
    
    # Invalidate cache if revoke was successful
    if success:
        invalidate_api_key_cache(key_id)
        logger.info(f"      🚫 API key revoked and cache invalidated (key_id: {key_id[:8]}...)")
    
    return success


async def delete_api_key(user_id: str, key_id: str) -> bool:
    """Permanently delete an API key and invalidate cache."""
    supabase = get_supabase_client()
    
    # Invalidate cache BEFORE delete (we still have the key_id)
    invalidate_api_key_cache(key_id)
    
    result = supabase.table("user_api_keys").delete().eq(
        "id", key_id
    ).eq("user_id", user_id).execute()
    
    success = len(result.data) > 0 if result.data else False
    if success:
        logger.info(f"      🗑️ API key deleted (key_id: {key_id[:8]}...)")
    
    return success
