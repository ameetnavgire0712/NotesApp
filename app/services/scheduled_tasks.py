"""
Scheduled tasks for log export
"""
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from datetime import datetime
import logging
import os

logger = logging.getLogger(__name__)

class ScheduledTaskManager:
    """Manages scheduled background tasks"""
    
    _scheduler = None
    
    @classmethod
    def init_scheduler(cls):
        """Initialize the scheduler"""
        if cls._scheduler is None:
            cls._scheduler = AsyncIOScheduler()
            logger.info("Initialized APScheduler")
        return cls._scheduler
    
    @classmethod
    async def start_scheduler(cls):
        """Start the scheduler"""
        scheduler = cls.init_scheduler()
        if not scheduler.running:
            scheduler.start()
            logger.info("Started APScheduler")
    
    @classmethod
    async def stop_scheduler(cls):
        """Stop the scheduler"""
        if cls._scheduler and cls._scheduler.running:
            cls._scheduler.shutdown()
            logger.info("Stopped APScheduler")
    
    @classmethod
    async def add_daily_log_export(cls):
        """Add daily log export tasks"""
        scheduler = cls.init_scheduler()
        
        # Import here to avoid circular imports
        from app.api.v1.log_export import export_supabase_logs_task, export_cloudflare_logs_task
        
        # Export Supabase logs daily at 01:00 UTC
        scheduler.add_job(
            export_supabase_logs_task,
            CronTrigger(hour=1, minute=0),
            args=[f"scheduled_{datetime.utcnow().strftime('%Y%m%d')}"],
            id='export_supabase_logs_daily',
            name='Export Supabase logs daily',
            replace_existing=True,
            misfire_grace_time=300  # 5 minutes grace period
        )
        logger.info("Added daily Supabase log export job (01:00 UTC)")
        
        # Export Cloudflare logs daily at 01:30 UTC
        # Only if CLOUDFLARE_API_TOKEN is configured
        if os.getenv("CLOUDFLARE_API_TOKEN"):
            scheduler.add_job(
                export_cloudflare_logs_task,
                CronTrigger(hour=1, minute=30),
                args=[f"cf_scheduled_{datetime.utcnow().strftime('%Y%m%d')}"],
                id='export_cloudflare_logs_daily',
                name='Export Cloudflare logs daily',
                replace_existing=True,
                misfire_grace_time=300
            )
            logger.info("Added daily Cloudflare log export job (01:30 UTC)")
        else:
            logger.warning("CLOUDFLARE_API_TOKEN not set - skipping Cloudflare log export scheduling")
        
        logger.info("Log export schedule configured")

# Global instance
task_manager = ScheduledTaskManager()
