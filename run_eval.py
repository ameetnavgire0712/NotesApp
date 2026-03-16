import asyncio
import sys
sys.path.insert(0, '.')
from app.services.ragas_evaluator import RAGASEvaluator

async def main():
    evaluator = RAGASEvaluator()
    result = await evaluator.run_evaluation()
    print(f'\n========== EVALUATION RESULTS ==========')
    print(f'Total evaluated: {result.total_evaluated}')
    print(f'Faithfulness:      {result.avg_faithfulness:.3f}')
    print(f'Context Precision: {result.avg_context_precision:.3f}')
    print(f'Context Recall:    {result.avg_context_recall:.3f}')
    print(f'Answer Relevancy:  {result.avg_answer_relevancy:.3f}')
    print(f'==========================================')

if __name__ == "__main__":
    asyncio.run(main())
