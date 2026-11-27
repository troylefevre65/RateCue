#!/usr/bin/env python3
"""Calls the bundled RateCue MCP helper from the command line, for scripts and test harnesses.

  mcp-call.py list                         List the tools the helper offers.
  mcp-call.py <tool> ['<json arguments>']  Call one tool and print its structured result.

Add --control to offer the opt-in control tools for this one helper process.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("local_agent", Path(__file__).with_name("local-agent.py"))
agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agent)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tool", help="'list' or a tool name")
    parser.add_argument("arguments", nargs="?", default="{}", help="JSON object of tool arguments")
    parser.add_argument("--control", action="store_true", help="Set RATECUE_MCP_ALLOW_CONTROL=1 for the helper")
    args = parser.parse_args()
    try:
        arguments = json.loads(args.arguments)
        if not isinstance(arguments, dict):
            raise ValueError("Tool arguments must be a JSON object.")
        client = agent.MCPClient(control=args.control)
        try:
            client.start()
            if args.tool == "list":
                tools = client.request("tools/list", {}).get("tools", [])
                print(json.dumps([
                    {"name": tool["name"], "readOnly": tool["annotations"]["readOnlyHint"],
                     "description": tool["description"]} for tool in tools
                ], indent=2))
                return 0
            result = client.request("tools/call", {"name": args.tool, "arguments": arguments})
        finally:
            client.close()
    except (agent.AgentError, OSError, ValueError) as error:
        print(f"MCP call failed: {error}", file=sys.stderr)
        return 2
    if result.get("isError"):
        print(json.dumps({"error": result["content"][0]["text"]}, indent=2))
        return 1
    print(json.dumps(result.get("structuredContent"), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
