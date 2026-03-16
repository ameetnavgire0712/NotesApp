"""Test evaluator config."""
import asyncio
from app.services.ragas_evaluator import RAGASEvaluator

async def test():
    evaluator = RAGASEvaluator()
    # Clear cache 
    evaluator._config_cache = None
    evaluator._config_cache_time = None
    
    config = await evaluator.get_config()
    print('Config from evaluator:')
    print(f'  sample_percentage: {config.get("sample_percentage")}')
    print(f'  llm_judge_model: {config.get("llm_judge_model")}')
    print(f'  min_queries_for_eval: {config.get("min_queries_for_eval")}')

asyncio.run(test())
