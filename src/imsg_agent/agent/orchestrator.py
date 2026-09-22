"""Agent Orchestrator — Core AI agent loop with tool calling.

Manages the conversation flow between the user and Ollama:
1. Receives natural language input from the user
2. Calls Ollama with conversation history + tool schemas
3. Validates tool call arguments via Pydantic (validator.py)
4. Checks guardrails for mutating actions (send, schedule, cancel)
5. Prompts user confirmation before execution
6. Executes approved tool calls via the tool registry
7. Returns tool results to the model for a final response
8. Falls back to regex parser if the model fails to produce tool calls

Key constraints:
- Maximum 5 tool-calling iterations per user input
- Context window capped at 10 messages (older turns summarized)
- Mutating actions always require user confirmation
"""
from __future__ import annotations

# TODO: Implement Agent class
# TODO: Implement process_input(user_input) -> str
# TODO: Implement _handle_tool_call(call) -> dict
# TODO: Implement _trimmed_history() for context management
# TODO: Implement _prompt_confirmation() for user approval
# TODO: Implement reset() to clear conversation history
