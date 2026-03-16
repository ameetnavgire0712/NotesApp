"""Quick test script to check evaluation config and run evaluation"""
import requests
import json

BASE_URL = "http://127.0.0.1:8000"

def main():
    # Check config
    print("=== Checking Config ===")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/evaluation/config", timeout=10)
        config = r.json()
        print(f"sample_percentage: {config.get('sample_percentage')}")
        print(f"llm_judge_model: {config.get('llm_judge_model')}")
    except Exception as e:
        print(f"Error getting config: {e}")
        return
    
    # Run evaluation
    print("\n=== Running Evaluation ===")
    try:
        r = requests.post(f"{BASE_URL}/api/v1/evaluation/run", timeout=300)
        result = r.json()
        print(f"run_id: {result.get('run_id')}")
        print(f"total_evaluated: {result.get('total_evaluated')}")
        print(f"total_sampled: {result.get('total_sampled')}")
        if result.get('total_evaluated', 0) > 0:
            print(f"faithfulness: {result.get('faithfulness')}")
            print(f"context_precision: {result.get('context_precision')}")
            print(f"context_recall: {result.get('context_recall')}")
            print(f"answer_relevancy: {result.get('answer_relevancy')}")
            
            # Get run details
            run_id = result.get('run_id')
            if run_id:
                print(f"\n=== Run Details for {run_id} ===")
                r2 = requests.get(f"{BASE_URL}/api/v1/evaluation/history/{run_id}", timeout=30)
                details = r2.json()
                print(f"individual_results count: {len(details.get('individual_results', []))}")
                for i, res in enumerate(details.get('individual_results', [])[:5]):
                    print(f"  [{i+1}] Query: {res.get('query', '')[:50]}...")
                    print(f"      Faithfulness: {res.get('faithfulness_score')}, Relevancy: {res.get('answer_relevancy_score')}")
        else:
            print("No queries evaluated - check sample_percentage")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()
