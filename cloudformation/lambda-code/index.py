"""
Lambda function for Bedrock Agent Action Group
Bridges Bedrock Agent calls to CARLA EC2 MCP server
"""

import json
import os
import requests
from typing import Dict, Any


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler for Bedrock Agent action group

    Event structure from Bedrock Agent:
    {
        "messageVersion": "1.0",
        "agent": {...},
        "inputText": "...",
        "sessionId": "...",
        "actionGroup": "...",
        "function": "function_name",
        "parameters": [{"name": "param1", "value": "value1"}, ...]
    }
    """

    print(f"Received event: {json.dumps(event)}")

    # Get CARLA EC2 endpoint from environment
    carla_endpoint = os.environ.get('CARLA_EC2_ENDPOINT', 'http://localhost:8000')

    # Extract function and parameters
    action_group = event.get('actionGroup', '')
    function_name = event.get('function', '')
    parameters = event.get('parameters', [])

    # Convert parameters list to dict
    params_dict = {p['name']: p['value'] for p in parameters}

    try:
        # Route to appropriate CARLA MCP endpoint
        if function_name == 'start_carla_scenario':
            result = start_carla_scenario(carla_endpoint, params_dict)
        elif function_name == 'run_vad_inference':
            result = run_vad_inference(carla_endpoint, params_dict)
        elif function_name == 'get_simulation_metrics':
            result = get_simulation_metrics(carla_endpoint, params_dict)
        elif function_name == 'stop_scenario':
            result = stop_scenario(carla_endpoint, params_dict)
        else:
            result = {
                'status': 'error',
                'message': f'Unknown function: {function_name}'
            }

        # Return response in Bedrock Agent format
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': action_group,
                'function': function_name,
                'functionResponse': {
                    'responseBody': {
                        'TEXT': {
                            'body': json.dumps(result)
                        }
                    }
                }
            }
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': action_group,
                'function': function_name,
                'functionResponse': {
                    'responseBody': {
                        'TEXT': {
                            'body': json.dumps({
                                'status': 'error',
                                'message': str(e),
                                'error_type': type(e).__name__
                            })
                        }
                    }
                }
            }
        }


def start_carla_scenario(endpoint: str, params: Dict[str, str]) -> Dict[str, Any]:
    """Start CARLA scenario via MCP"""
    url = f"{endpoint}/mcp/start_carla_scenario"

    payload = {
        'map_name': params.get('map_name', 'Town05'),
        'weather': params.get('weather', 'ClearNoon'),
        'num_vehicles': int(params.get('num_vehicles', 50)),
        'num_pedestrians': int(params.get('num_pedestrians', 30))
    }

    response = requests.post(url, json=payload, timeout=30)
    response.raise_for_status()

    return response.json()


def run_vad_inference(endpoint: str, params: Dict[str, str]) -> Dict[str, Any]:
    """Run VAD inference via MCP"""
    url = f"{endpoint}/mcp/run_vad_inference"

    payload = {
        'duration_seconds': int(params.get('duration_seconds', 10)),
        'save_results': params.get('save_results', 'true').lower() == 'true',
        'output_path': params.get('output_path', '/tmp/vad_results.json')
    }

    response = requests.post(url, json=payload, timeout=300)
    response.raise_for_status()

    return response.json()


def get_simulation_metrics(endpoint: str, params: Dict[str, str]) -> Dict[str, Any]:
    """Get simulation metrics via MCP"""
    url = f"{endpoint}/mcp/get_simulation_metrics"

    response = requests.get(url, timeout=10)
    response.raise_for_status()

    return response.json()


def stop_scenario(endpoint: str, params: Dict[str, str]) -> Dict[str, Any]:
    """Stop scenario via MCP"""
    url = f"{endpoint}/mcp/stop_scenario"

    response = requests.post(url, timeout=10)
    response.raise_for_status()

    return response.json()
