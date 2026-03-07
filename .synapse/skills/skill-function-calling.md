---
name: Function Calling (Tools) – xAI API
tags: [xai, grok, api, tools, function-calling, agent]
---

# Skill: Function Calling (Tools) – xAI API

**Category**: Tool Use / Agent Capabilities  
**API Models with strong support**: grok-4-1-fast-reasoning, grok-4 series, etc.  
**Documentation**: https://docs.x.ai/developers/tools/function-calling

## What it does

Lets Grok request execution of **custom tools** (client-side functions) you define.  
Grok → decides to call tool → returns structured tool call → you execute locally → return result → Grok continues.

Enables:
- Calling your APIs
- Querying internal databases
- Performing calculations / file operations
- Interacting with local systems

Complements **server-side built-in tools** (web_search, x_keyword_search, code_execution, etc.).

## Core Format – Tool Definition

Every tool is a JSON object. **xAI API requires a nested `function` object** (name, description, parameters inside `function`):

```json
{
  "type": "function",
  "function": {
    "name": "get_current_weather",
    "description": "Get the current weather in a given location. Use this when user asks about weather, temperature, forecast.",
    "parameters": {
      "type": "object",
      "properties": {
        "location": {
          "type": "string",
          "description": "City name and optionally state/country, e.g. 'Tokyo', 'San Francisco, CA', 'Paris, France'"
        },
        "unit": {
          "type": "string",
          "enum": ["celsius", "fahrenheit"],
          "description": "Temperature unit",
          "default": "celsius"
        }
      },
      "required": ["location"]
    }
  }
}
```

**Required fields**
- `type`: always `"function"`
- `function`: object containing `name`, `description`, `parameters` (xAI nests these under `function`)

## Supported Parameter Features (JSON Schema subset)

| Feature          | Example                                          | Purpose                                 |
|------------------|--------------------------------------------------|-----------------------------------------|
| type             | "string", "number", "integer", "boolean", "object", "array" | Basic type                             |
| description      | "The city to look up"                            | Helps model understand & fill correctly |
| enum             | ["celsius", "fahrenheit"]                        | Restrict to allowed values              |
| default          | "celsius"                                        | Fallback if not provided                |
| required         | ["location", "date"]                             | Must be present                         |

Nested objects and arrays are supported.

## Tool Call Flow (simplified)

1. Send `tools: [tool1, tool2, ...]` in chat request
2. Grok responds with `tool_calls: [{id, type:"function", function: {name, arguments}}]`
3. You parse `arguments` (JSON string) → execute real function
4. Append new message:  
   ```json
   {
     "role": "tool",
     "tool_call_id": "call_abc123",
     "name": "get_current_weather",
     "content": "{\"temperature\": 22, \"unit\": \"celsius\", \"condition\": \"sunny\"}"
   }
   ```
5. Send back to model → it continues reasoning

## Important Controls

| Option                  | Values                              | Effect                                          |
|-------------------------|-------------------------------------|-------------------------------------------------|
| tool_choice             | "auto" (default), "required", "none", {type:"function", function:{name:"..."}} | Control whether / which tool must be used      |
| parallel_tool_calls     | true (default) / false              | Allow multiple tool calls in one response       |
| Max tools per request   | ≤ 200                               | Practical limit                                 |

## Best Practices

- Write extremely clear, specific **descriptions** — this is 80% of getting reliable tool use
- Use **examples** in descriptions when behavior is non-obvious
- Prefer **snake_case** for tool & parameter names
- Return clean JSON strings from tools (not pretty-printed)
- Handle errors gracefully → return `{"error": "City not found"}`
- Use **Pydantic / Zod / JSON Schema validators** to avoid crashes from malformed arguments
- For very complex tools → split into multiple focused tools
- Test with `tool_choice: "required"` to force usage during development

## Quick Mental Model

Grok has eyes (vision), mouth (text), and now **hands** (your functions).  
The better you describe what each hand can do, the more intelligently Grok will reach for the right one.
